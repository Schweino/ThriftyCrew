<#
  build-fareway-regular.ps1 - turns the Fareway STOREFRONT extracts (shop.fareway.com, no-markup in-store
  prices, Omaha) into an engine-ready everyday-price file: out\regular\fareway-regular-<date>.json.
  compare-deals.ps1 auto-discovers out\regular\<store>-regular-*.json (price_type=everyday) with NO code
  change, so writing this file is all it takes to put Fareway's current shelf prices into the comparison.

  Input: one or more raw extract files (default: out\fareway\fareway-shop-*.json), each a JSON array of
  { id, name, price, per, orig, unit, size } as produced by the browser DOM extractor. For each commodity id
  we emit the engine's {store,item,ad_price,size,regular} using the store's existing unit conventions:
    - weighted goods (unit like "$4.99/lb")  -> ad_price="$4.99", size="lb"   (per-unit price)
    - "$X per pound"                          -> ad_price="$X",    size="lb"
    - sold each (per="each", no /lb)          -> ad_price="$X",    size="each"
    - packaged                                -> ad_price="$price",size=<package size>
    - milk  -> size "gallon"     (1-gal pack price is per gallon)
    - eggs  -> size "dozen"      (per-dozen price computed from the count)
  Last writer wins per id (pass core first, then the rest). Skips NOT FOUND / empty-price rows.
#>
param([string[]]$In = @(), [string]$OutDir = "", [string]$Today = "", [string]$ModeVerified = "", [switch]$Force,
  # See the EXTRACT DATING block below. 14 days is not a new policy number - it is the same cap
  # carry-forward-regular.ps1 already applies to every row it copies, applied here to the extracts this
  # script merges, because merging an old extract and carrying an old row are the same act.
  [int]$MaxExtractDays = 14,
  # -SelfTest runs the frozen fixtures below by RE-INVOKING this very script over a fixture capture, so the
  # assertions exercise the real emit path end to end instead of a copy of it (the 2026-07-29 lesson: two
  # same-day fixes regressed because their self-test could not reach the new code).
  [switch]$SelfTest,
  # -NoCarry suppresses the carry-forward/size-heal tail. ONLY the self-test child passes it: those two
  # scripts resolve out\regular from $PSScriptRoot, not from -OutDir, so a fixture run would otherwise
  # reach into the live board.
  [switch]$NoCarry)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$asofS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
if (-not $In -or $In.Count -eq 0) {
  $In = @(Get-ChildItem (Join-Path $OutDir 'fareway\fareway-shop-*.json') -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
}
. (Join-Path $root 'capture-lib.ps1')   # UTF-8 capture read + mojibake repair, shared by every builder

# ---------------------------------------------------------------- SLUG SIZE (2026-08-01, triage 9da3a8)
# The Fareway storefront DOM does not carry the pack size for many products: this builder writes size='each'
# or '' while the price is the PACK price. The engine then (correctly) refuses to price a size-less row on a
# per-unit commodity, and on 2026-07-31 the 14-day carry cap expired the last 196 SIZED rows at once, so 21
# commodities lost their Fareway cell overnight. The catalog SLUG carries the size the DOM omitted
# (".../20544533-fareway-drinking-water-purified-24-each" is a 24-pack), so it is the declared fallback
# surface - with four refusals, because a wrongly adopted size mints a WRONG per-unit price and a wrong price
# is worse than a missing cell:
#   1. PACK NAME. "Pepsi Soda - Pack" + slug "12-fl-oz": the slug names the CAN, the price is the PACK.
#      Adopting it recreates the Aldi pack-price-as-unit-size bug (triage 2026-07-31-96ae4a).
#   2. VOLUME SLUG. The same trap WITHOUT the "- Pack" suffix, which is why the name test alone is not enough:
#      "Shasta Cola, Diet" ($4.98) and "Gatorade Orange Thirst Quencher" ($8.48) both carry a single-serving
#      fl-oz slug against a multipack price, and nothing in the slug distinguishes them from a real 64 fl oz
#      bottle. So a fl-oz/gal slug is adopted only when the NAME states the same number. Measured cost of this
#      refusal on the 2026-07-31 capture set: zero rows - every legitimate fl-oz row (Old Orchard 64 fl oz)
#      already carries its own captured size and never reaches this path.
#   3. DASHLESS 3+ DIGIT WEIGHT. The slug writes a decimal point as a dash ("...-cake-mix-15-25-oz" = 15.25 oz)
#      but sometimes drops it entirely ("...-macaroni-cheese-dinner-725-oz" is a 7.25 oz box). A 3+ digit
#      dashless weight token is therefore unreadable, and it is refused for the CONFLICT test as well as for
#      adoption: an unreadable token must never be allowed to condemn a captured size that is perfectly
#      correct. (mac-and-cheese captures a true "7.25 oz" and would otherwise be dropped for "disagreeing"
#      with its own slug by 100x.) Counts carry no decimals, so an integer count is safe at any length.
#   4. SIZE CONFLICT. A captured size that disagrees with a READABLE slug size by 1.5x or more is two
#      statements of one fact contradicting each other; no number is honest, so the row is dropped and NAMED
#      through the existing basis-conflict path. Softsoap captures "221 fl oz" against a 7.5 oz slug (30x);
#      Hawaiian Punch captures "512 fl oz" against a 1 gal = 128 fl oz slug (4x).
$SLUG_UNITS = @{
  'ct'    = @{ canon = 'ct';    family = 'count';   oz = 0;   volume = $false }
  'each'  = @{ canon = 'ct';    family = 'count';   oz = 0;   volume = $false }
  'ea'    = @{ canon = 'ct';    family = 'count';   oz = 0;   volume = $false }
  'count' = @{ canon = 'ct';    family = 'count';   oz = 0;   volume = $false }
  'oz'    = @{ canon = 'oz';    family = 'measure'; oz = 1;   volume = $false }
  'lb'    = @{ canon = 'lb';    family = 'measure'; oz = 16;  volume = $false }
  'lbs'   = @{ canon = 'lb';    family = 'measure'; oz = 16;  volume = $false }
  'fl-oz' = @{ canon = 'fl oz'; family = 'measure'; oz = 1;   volume = $true }
  'gal'   = @{ canon = 'gal';   family = 'measure'; oz = 128; volume = $true }
}
# g / ml / l / sq-ft / pack / pk / inch are deliberately NOT adoptable: either the engine has no basis for
# them here, or (pack/pk) the token is a count of containers, not a size.
function Get-SlugSize([string]$url, [string]$name) {
  if (-not $url) { return $null }
  $tail = @((($url -replace '[?#].*$', '') -replace '/+$', '') -split '/')[-1]
  $m = [regex]::Match($tail, '-(?<num>\d+(?:-\d+)?)-(?<unit>fl-oz|lbs|lb|oz|gal|count|each|ea|ct)$')
  if (-not $m.Success) { return $null }
  $u = $SLUG_UNITS[$m.Groups['unit'].Value]
  if (-not $u) { return $null }
  $raw = $m.Groups['num'].Value
  # NOTE: never use $Matches here. A nested -match anywhere in this call chain clobbers it, and this estate
  # has already shipped that bug once. Read the groups off the Match object.
  $dm = [regex]::Match($raw, '^(\d+)-(\d+)$')
  $n = 0.0
  if ($dm.Success) { $n = [double]($dm.Groups[1].Value + '.' + $dm.Groups[2].Value) }   # refusal 3: dash IS the decimal point
  else {
    # A LEADING ZERO is a decimal point that fell off, at any length: Fareway's own 2% milk is
    # ".../fareway-2-reduced-fat-milk-05-gal" and it is a HALF gallon, not five gallons. Reading "05" as 5
    # made the size-conflict test condemn the correct captured "0.5 gal" and drop MILK off the board.
    if (($raw.Length -gt 1) -and $raw.StartsWith('0')) {
      return @{ ok = $false; reason = ("leading-zero token '" + $raw + "' - the slug dropped a decimal point (0.5 gal is spelled 05-gal)") }
    }
    if (($u.family -ne 'count') -and ($raw.Length -ge 3) -and -not ($name -match ('(?<![\d.])' + $raw + '(?![\d.])'))) {
      return @{ ok = $false; reason = ("ambiguous dashless weight token '" + $raw + "' (7.25 oz and 725 oz are spelled the same)") }
    }
    $n = [double]$raw
  }
  if ($n -le 0) { return $null }
  # READABLE and ADOPTABLE are different questions and conflating them cost a real quarantine in test (b2).
  #   ok        = the token states a size we can READ. Only the dashless-3+-digit ambiguity above defeats this.
  #   adoptable = we may also PUBLISH that size. A volume slug with no corroborating number in the name is
  #               readable but not adoptable: "1 gal" and "20 fl oz" are perfectly clear statements about ONE
  #               container, and the risk is that the PRICE is for a multipack of them.
  # The conflict test needs only readability - Hawaiian Punch's "1 gal" is exactly what proves its captured
  # "512 fl oz" wrong, and gating the comparison on adoptability let that row publish.
  $adoptable = $true; $why = ''
  if ($u.volume) {
    $numTxt = ('{0:0.####}' -f $n)
    if (-not ($name -match ('(?<![\d.])' + [regex]::Escape($numTxt) + '(?![\d.])'))) {
      $adoptable = $false; $why = 'volume slug with no corroborating size in the product name (multipack-price risk)'
    }
  }
  return @{ ok = $true; adoptable = $adoptable; reason = $why; raw = $raw; n = $n; canon = $u.canon; family = $u.family; ozEquiv = ($n * $u.oz); text = ('{0:0.####} {1}' -f $n, $u.canon) }
}
# The size the CAPTURE stated, normalised, for the conflict test and for count recovery. Deliberately strict:
# it only reads a clean leading "<number> <unit>", so "About 4.0 lb / package" yields nothing and no conflict
# is asserted from a phrase this function does not actually understand.
function Get-CapturedMeasure([string]$s) {
  if (-not $s) { return $null }
  $m = [regex]::Match($s.Trim().ToLower(), '^(?<n>\d+(?:\.\d+)?)\s*(?<u>fl\s*oz|fluid\s*ounces?|ounces?|oz|lbs?|pounds?|gal(?:lons?)?|count|each|ea|ct)\b')
  if (-not $m.Success) { return $null }
  $n = [double]$m.Groups['n'].Value
  if ($n -le 0) { return $null }
  $u = $m.Groups['u'].Value
  if ($u -match '^(ct|count|each|ea)$') { return @{ n = $n; family = 'count'; ozEquiv = $n } }
  $mult = 1.0
  if ($u -match '^(lbs?|pounds?)$') { $mult = 16 } elseif ($u -match '^gal') { $mult = 128 }
  return @{ n = $n; family = 'measure'; ozEquiv = ($n * $mult) }
}
if ($SelfTest) {
  # FROZEN FIXTURES - every row below is copied verbatim out of a real capture
  # (out\fareway\fareway-shop-2026-07-31.json, and -07-23 for the Gatorade row). They are frozen on purpose:
  # regenerating them from the live capture would erase the very bug they encode and the test would then
  # pass by finding nothing. The test RE-INVOKES this script over them, so it exercises the real emit path
  # (including the each-unit fixup that used to eat the recovered count) rather than a copy of the logic.
  $fail = 0
  $T = Join-Path $env:TEMP ('bfr-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $T -Force | Out-Null
  try {
    $fx = @(
      # (a) MUST FIRE: pack count exists ONLY in the slug -> recovered as a count
      @{ id = 'bottled-water'; name = 'Fareway Purified Drinking Water'; price = '3.87'; per = ''; orig = '4.49'; unit = ''; size = ''; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/20544533-fareway-drinking-water-purified-24-each' },
      # (b) MUST FIRE: captured size 30x the slug -> basis conflict, never published
      @{ id = 'hand-soap'; name = 'Softsoap Liquid Hand Soap Pump, Fresh Breeze'; price = '1.99'; per = ''; orig = '2.99'; unit = ''; size = '221 fl oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/17105464-softsoap-hand-soap-fresh-breeze-7-5-oz' },
      # (b2) MUST FIRE: 512 fl oz against a 1 gal slug -> basis conflict
      @{ id = 'fruit-punch'; name = 'Hawaiian Punch Multi-serve Polar Blast Juice Drink'; price = '3.48'; per = ''; orig = '3.99'; unit = ''; size = '512 fl oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/34483-hawaiian-punch-polar-blast-juice-drink-1-gal' },
      # (c) MUST FIRE: "- Pack" name + per-can slug -> stays size-less
      @{ id = 'soda'; name = 'Pepsi Soda - Pack'; price = '9.49'; per = ''; orig = ''; unit = ''; size = ''; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/42309-pepsi-cola-12-fl-oz' },
      # (d) MUST FIRE: dashless "725-oz" is 7.25 oz - unreadable, so it may neither be adopted NOR used to
      #     condemn the correct captured size. The row must survive.
      @{ id = 'mac-and-cheese'; name = 'Fareway Original Macaroni & Cheese Dinner'; price = '0.68'; per = ''; orig = '0.99'; unit = ''; size = '7.25 oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/69966184-fareway-original-macaroni-cheese-dinner-725-oz' },
      # (e) CLEAN TWIN: the 2026-07-23 "-1-lb" basis override keeps today's behaviour exactly
      @{ id = 'apples'; name = 'Granny Smith Apple'; price = '0.84'; per = 'each'; orig = '1.00'; unit = '$1.68/lb'; size = 'About 0.5 lb each'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/16516401-granny-smith-apple-1-lb' },
      # (f) CLEAN TWIN: a real captured size with an AGREEING slug passes through untouched
      @{ id = 'tomatoes'; name = 'NatureSweet Cherubs Tomatoes'; price = '3.99'; per = ''; orig = ''; unit = ''; size = '10 oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/20337467-naturesweet-salad-tomatoes-heavenly-10-oz' },
      # (g) MUST FIRE: the pack trap WITHOUT a "- Pack" suffix. $8.48 is a multipack price, the slug names one
      #     20 fl oz bottle, and only the volume refusal stops a 4x-wrong per-unit here.
      @{ id = 'sports-drinks'; name = 'Gatorade Orange Thirst Quencher, Sports Drink'; price = '8.48'; per = ''; orig = '8.99'; unit = ''; size = ''; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/224714-gatorade-orange-thirst-quencher-sports-drink-20-fl-oz' },
      # (h) MUST FIRE: the capture DID carry the count ("28 each") and the each-unit fixup used to drop it
      @{ id = 'trash-bags'; name = 'Bright Essentials Trash Bags, Black, Drawstring, Unscented, Large'; price = '7.88'; per = ''; orig = '8.99'; unit = ''; size = '28 each'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/39667951-bright-essentials-trash-bags-black-drawstring-unscented-large-28-each' },
      # (i) same class, three-digit count - proves the length rule is weight-only
      @{ id = 'dryer-sheets'; name = 'Bright Essentials Dryer Sheets, Wrinkle Reducing, Unscented'; price = '3.94'; per = ''; orig = '5.94'; unit = ''; size = '120 each'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/26952710-bright-essentials-dryer-sheets-wrinkle-reducing-unscented-120-each' },
      # (j)-(m) MUST-NOT-FIRE twins for the size-conflict quarantine. All four were dropped by the first,
      # literal version of the 1.5x rule and all four are the SLUG being wrong about a correct capture.
      # They are frozen here because that over-drop is invisible on a healthy board: a quarantined row just
      # looks like a store that does not carry the item.
      @{ id = 'air-freshener'; name = 'Glade Lavender Air Freshener'; price = '1.48'; per = ''; orig = ''; unit = ''; size = '7.3 oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/91205-lavender-air-fresheners-73-oz' },
      @{ id = 'breakfast-sandwiches'; name = 'Jimmy Dean Croissant Breakfast Sandwiches with Sausage, Egg, and Cheese, Frozen, 4 Count'; price = '7.29'; per = ''; orig = ''; unit = ''; size = '18 oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/17046172-jimmy-dean-sausage-egg-cheese-croissant-breakfast-sandwiches-4-5-oz' },
      @{ id = 'milk'; name = 'Fareway 2% Reduced Fat Milk'; price = '3.15'; per = ''; orig = ''; unit = ''; size = '0.5 gal'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/17636844-fareway-2-reduced-fat-milk-05-gal' },
      @{ id = 'sugar-snap-peas'; name = 'Pero Family Farms Sugar Snap Peas'; price = '3.99'; per = ''; orig = ''; unit = ''; size = '8 oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/16610403-snap-peas-sugar-15-oz' },
      # (n)/(o) the canonical-unit relabel discarding a real size - both were LIVE wrong prices on 2026-08-01
      @{ id = 'eggs'; name = 'Dutch Farms 18 Grade A Large Eggs'; price = '2.17'; per = ''; orig = ''; unit = ''; size = '36 oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/2915637-dutch-farms-18-grade-a-large-eggs-18-ct' },
      # (p) a WEIGHT on a per-item commodity is true and useless; the slug carries the count
      @{ id = 'croissants'; name = 'Fareway All Butter Croissants'; price = '5.99'; per = ''; orig = ''; unit = ''; size = '8.5 oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/84386686-fareway-all-butter-croissants-3-ct' }
    )
    # (n) uses the milk row already frozen at (l) above.
    $fxF = Join-Path $T 'fareway-shop-2026-07-31.json'
    ($fx | ConvertTo-Json -Depth 4) | Set-Content $fxF -Encoding UTF8
    $selfPath = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $root 'build-fareway-regular.ps1' }
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $selfPath -In $fxF -OutDir $T -Today '2026-07-31' -ModeVerified '2026-07-31' -NoCarry 2>&1 | Out-String
    $doc = Get-Content (Join-Path $T 'regular\fareway-regular-2026-07-31.json') -Raw | ConvertFrom-Json
    $byid = @{}; foreach ($d in @($doc.deals)) { $byid[[string]$d.item] = $d }
    function Chk([string]$label, [bool]$cond, [string]$got) {
      if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
    }
    $a = $byid['Fareway Purified Drinking Water']
    Chk '(a) slug-only pack count recovered      bottled-water -> "24 ct"' ($a -and $a.size -eq '24 ct') ("$($a.size)")
    Chk '(b) 221-vs-7.5 conflict never published hand-soap row absent' (-not $byid.ContainsKey('Softsoap Liquid Hand Soap Pump, Fresh Breeze')) 'row present'
    # Read the CONFLICT LINE itself, not the whole transcript: the builder also prints every emitted row at
    # the end, so "the name appears in $out" would pass for a row that was published rather than dropped.
    $conflictLine = (($out -split "`r?`n") | Where-Object { $_ -match 'BASIS CONFLICT' }) -join ' '
    Chk '(b) conflict is NAMED in the report' ($conflictLine -match 'Softsoap') "conflictLine=[$conflictLine]"
    Chk '(b2) 512-vs-1gal conflict never published fruit-punch row absent' (-not $byid.ContainsKey('Hawaiian Punch Multi-serve Polar Blast Juice Drink')) 'row present'
    Chk '(b2) conflict is NAMED in the report' ($conflictLine -match 'Hawaiian Punch') "conflictLine=[$conflictLine]"
    $c = $byid['Pepsi Soda - Pack']
    Chk '(c) "- Pack" name + per-can slug stays size-less' ($c -and [string]::IsNullOrEmpty([string]$c.size)) ("$($c.size)")
    $d = $byid['Fareway Original Macaroni & Cheese Dinner']
    Chk '(d) unreadable "725-oz" neither adopted nor used to drop the row' ($d -ne $null -and $out -notmatch 'Macaroni') ("$($d.size)")
    $e = $byid['Granny Smith Apple']
    Chk '(e) CLEAN TWIN "-1-lb" override unchanged  $1.68 / lb' ($e -and $e.ad_price -eq '$1.68' -and $e.size -eq 'lb') ("$($e.ad_price) / $($e.size)")
    $f = $byid['NatureSweet Cherubs Tomatoes']
    Chk '(f) CLEAN TWIN agreeing slug passes through 10 oz' ($f -and $f.size -eq '10 oz') ("$($f.size)")
    $g = $byid['Gatorade Orange Thirst Quencher, Sports Drink']
    Chk '(g) volume slug w/o a size in the NAME refused (multipack price)' ($g -and [string]::IsNullOrEmpty([string]$g.size)) ("$($g.size)")
    $h = $byid['Bright Essentials Trash Bags, Black, Drawstring, Unscented, Large']
    Chk '(h) captured "28 each" survives the each-unit fixup -> "28 ct"' ($h -and $h.size -eq '28 ct') ("$($h.size)")
    $i = $byid['Bright Essentials Dryer Sheets, Wrinkle Reducing, Unscented']
    Chk '(i) 3-digit COUNT is safe (weight-only length rule) -> "120 ct"' ($i -and $i.size -eq '120 ct') ("$($i.size)")
    Chk '(j) MUST NOT DROP  slug dropped the decimal ("73-oz" vs 7.3 oz)' ($byid.ContainsKey('Glade Lavender Air Freshener') -and $conflictLine -notmatch 'Glade') "conflictLine=[$conflictLine]"
    Chk '(k) MUST NOT DROP  slug names 1 of a "4 Count" pack (4 x 4.5 = 18 oz)' ($byid.ContainsKey('Jimmy Dean Croissant Breakfast Sandwiches with Sausage, Egg, and Cheese, Frozen, 4 Count') -and $conflictLine -notmatch 'Jimmy Dean') "conflictLine=[$conflictLine]"
    Chk '(l) MUST NOT DROP  leading-zero slug "05-gal" is half a gallon (MILK)' ($byid.ContainsKey('Fareway 2% Reduced Fat Milk') -and $conflictLine -notmatch 'Reduced Fat Milk') "conflictLine=[$conflictLine]"
    Chk '(m) MUST NOT DROP  slug LARGER than the capture is a slug fault, not a corruption' ($byid.ContainsKey('Pero Family Farms Sugar Snap Peas') -and $conflictLine -notmatch 'Sugar Snap') "conflictLine=[$conflictLine]"
    $n1 = $byid['Fareway 2% Reduced Fat Milk']
    Chk '(n) half-gallon price NOT relabelled per gallon  -> $3.15 / "0.5 gal"' ($n1 -and $n1.ad_price -eq '$3.15' -and $n1.size -eq '0.5 gal') ("$($n1.ad_price) / $($n1.size)")
    $o1 = $byid['Dutch Farms 18 Grade A Large Eggs']
    Chk '(o) 18-ct read from the slug, priced per dozen -> $1.45 / "dozen"' ($o1 -and $o1.ad_price -eq '$1.45' -and $o1.size -eq 'dozen') ("$($o1.ad_price) / $($o1.size)")
    $p1 = $byid['Fareway All Butter Croissants']
    Chk '(p) weight on a per-item commodity -> slug count wins  "3 ct"' ($p1 -and $p1.size -eq '3 ct') ("$($p1.size)")
    # CLEAN TWINS for (n)/(o), in their own child run because deals are keyed by commodity id and only one
    # milk row can survive a single pass. A gallon-unit row with NO usable volume must STILL be relabelled,
    # and a dozen-unit row with no count anywhere must still fall back to the undivided pack price.
    $fx2 = @(
      @{ id = 'milk'; name = 'Fareway Whole Milk'; price = '5.75'; per = ''; orig = ''; unit = ''; size = 'each'; url = '' },
      @{ id = 'eggs'; name = 'Country Daybreak Large White Eggs'; price = '1.47'; per = ''; orig = ''; unit = ''; size = ''; url = '' }
    )
    $fx2F = Join-Path $T 'twin\fareway-shop-2026-07-31.json'
    New-Item -ItemType Directory -Path (Join-Path $T 'twin') -Force | Out-Null
    ($fx2 | ConvertTo-Json -Depth 4) | Set-Content $fx2F -Encoding UTF8
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $selfPath -In $fx2F -OutDir (Join-Path $T 'twin') -Today '2026-07-31' -ModeVerified '2026-07-31' -NoCarry 2>&1
    $doc2 = Get-Content (Join-Path $T 'twin\regular\fareway-regular-2026-07-31.json') -Raw | ConvertFrom-Json
    $t1 = @($doc2.deals) | Where-Object { $_.item -eq 'Fareway Whole Milk' }
    $t2 = @($doc2.deals) | Where-Object { $_.item -eq 'Country Daybreak Large White Eggs' }
    Chk '(n twin) gallon row with no stated volume STILL relabelled "gallon"' ($t1 -and $t1.size -eq 'gallon' -and $t1.ad_price -eq '$5.75') ("$($t1.ad_price) / $($t1.size)")
    Chk '(o twin) dozen row with no count anywhere keeps the pack price undivided' ($t2 -and $t2.size -eq 'dozen' -and $t2.ad_price -eq '$1.47') ("$($t2.ad_price) / $($t2.size)")

    # ---- (q)-(t) EXTRACT DATING, its own child run because it needs THREE extracts of different ages ----
    # This script merges every extract in out\fareway and stamps the result. Until 2026-08-02 it stamped
    # them all with the BUILD date, so 431 of 577 live rows wore a date newer than the capture that produced
    # them and guard 9 read a fabricated 78% freshness against a true 9%. The ranch-dressing row below is the
    # founding case verbatim, caught at the shelf by the C3 sample: last seen in the 07-23/07-27/07-31
    # extracts, absent from 08-01, published as_of 2026-08-01, real shelf price $2.48 against a published
    # $0.99. Frozen with a THREE-file layout because the bug is invisible in any single-extract run.
    # NOTE the invocation: no -In. The child discovers its own extracts from -OutDir, both because that is
    # the real path this runs on and because a string[] does not survive `powershell -File` (it arrives
    # flattened into one element), which has cost this estate two same-day regressions.
    $mDir = Join-Path $T 'multi\fareway'
    New-Item -ItemType Directory -Path $mDir -Force | Out-Null
    (@(
      # 17 days old -> beyond the 14-day cap: the whole extract must be skipped and NAMED
      @{ id = 'bottled-water'; name = 'Fareway Purified Drinking Water'; price = '1.11'; per = ''; orig = ''; unit = ''; size = '24 ct'; url = '' }
    ) | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $mDir 'fareway-shop-2026-07-15.json') -Encoding UTF8
    (@(
      # 9 days old -> inside the cap, so it still prices the board, but it must SAY 2026-07-23
      @{ id = 'ranch-dressing'; name = 'Fareway Ranch Dressing'; price = '0.99'; per = ''; orig = ''; unit = ''; size = '16 fl oz'; url = '' },
      @{ id = 'tomatoes'; name = 'NatureSweet Cherubs Tomatoes'; price = '9.99'; per = ''; orig = ''; unit = ''; size = '10 oz'; url = '' }
    ) | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $mDir 'fareway-shop-2026-07-23.json') -Encoding UTF8
    (@(
      @{ id = 'tomatoes'; name = 'NatureSweet Cherubs Tomatoes'; price = '3.99'; per = ''; orig = ''; unit = ''; size = '10 oz'; url = '' }
    ) | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $mDir 'fareway-shop-2026-08-01.json') -Encoding UTF8
    $out3 = & powershell -NoProfile -ExecutionPolicy Bypass -File $selfPath -OutDir (Join-Path $T 'multi') -Today '2026-08-01' -ModeVerified '2026-08-01' -NoCarry 2>&1 | Out-String
    $doc3 = Get-Content (Join-Path $T 'multi\regular\fareway-regular-2026-08-01.json') -Raw | ConvertFrom-Json
    $b3 = @{}; foreach ($d in @($doc3.deals)) { $b3[[string]$d.item] = $d }
    $q1 = $b3['Fareway Ranch Dressing']
    Chk '(q) row from a 07-23 extract keeps as_of 2026-07-23, NOT the build date' ($q1 -and $q1.as_of -eq '2026-07-23') ("as_of=$($q1.as_of)")
    Chk '(r) extract 17 days old is skipped whole - its row never publishes' (-not $b3.ContainsKey('Fareway Purified Drinking Water')) 'row present'
    $agedLine = (($out3 -split "`r?`n") | Where-Object { $_ -match 'AGED OUT' }) -join ' '
    Chk '(r) the skipped extract is NAMED, not quietly dropped' ($agedLine -match '2026-07-15') "agedLine=[$agedLine]"
    $s1 = $b3['NatureSweet Cherubs Tomatoes']
    Chk '(s) CLEAN TWIN today''s extract still dates as today  2026-08-01' ($s1 -and $s1.as_of -eq '2026-08-01') ("as_of=$($s1.as_of)")
    Chk '(t) CLEAN TWIN last-writer-wins survives  $3.99 beats the older $9.99' ($s1 -and $s1.ad_price -eq '$3.99') ("$($s1.ad_price)")
  } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$commod = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$validSet = @{}; $unitMap = @{}; $pintMap = @{}; foreach ($c in $commod) { $validSet[[string]$c.id] = $true; $unitMap[[string]$c.id] = [string]$c.unit; if ($c.PSObject.Properties['pint_oz'] -and $c.pint_oz) { $pintMap[[string]$c.id] = [double]$c.pint_oz } }

$byId = [ordered]@{}
$byUrl = [ordered]@{}
# Rows dropped because the catalog slug and the commodity's canonical unit state different bases. Reported
# below rather than silently swallowed: a dropped cell must always be a named decision, never a quiet gap.
$basisConflicts = 0
$basisConflictIds = @()

# ------------------------------------------------- EXTRACT DATING (2026-08-02, found by the C3 sample)
# A ROW'S as_of IS THE DATE OF THE EXTRACT IT CAME FROM, never the date of this build. This script reads
# EVERY out\fareway\fareway-shop-*.json and takes last-writer-wins per commodity - that merge is a coverage
# feature and it stays - but it used to stamp all of them with -Today. Measured on the live 08-01 file:
# 431 of 577 published rows carried a date NEWER than the extract that supplied them, and 450 rows claimed
# as_of=2026-08-01 when only 51 came from that day's extract.
# WHY A LAUNDERED DATE IS WORSE THAN A MISSING ONE. Guard 9 measures this store's freshness as "rows whose
# as_of == today", so the stamp fed the staleness guard a fabricated 78% against a true 9%: the only check
# watching this store's clock was reading a number this script had written to be true, and no amount of
# staleness could ever move it. Out-of-band verification C3 caught the consequence at the shelf - 'Fareway
# Ranch Dressing' $0.99 last appears in the 07-23/07-27/07-31 extracts, is absent from 08-01, published
# as_of 2026-08-01, and the store charges $2.48 (the board printed $0.0619/floz against a real $0.155).
# Three of the four measured Fareway defects are this one mechanism.
# THE CAP. Honest dating alone still lets an arbitrarily old extract price the board - the 07-15 file was
# still supplying a live cell 18 days on - so an extract older than -MaxExtractDays is dropped whole and
# NAMED. Merging a 3-week-old extract and carrying a 3-week-old row are the same act, so it is the same cap.
# The date comes from the FILENAME, which is how every other dated surface in this estate is read; a file
# that does not carry one falls back to its mtime and is reported, because guessing "today" here is the
# exact bug being fixed.
$buildDate = [datetime]$asofS
$srcDates = @{}
$agedOut = @()
$undatedSrc = @()
$keptIn = New-Object System.Collections.Generic.List[string]
foreach ($f in @($In)) {
  if (-not (Test-Path $f)) { continue }
  $bn = [System.IO.Path]::GetFileNameWithoutExtension($f)
  $dm = [regex]::Match($bn, '(\d{4}-\d{2}-\d{2})$')
  $sd = $null
  if ($dm.Success) { try { $sd = [datetime]$dm.Groups[1].Value } catch { $sd = $null } }
  if (-not $sd) {
    $sd = (Get-Item $f).LastWriteTime.Date
    $undatedSrc += ("{0} (no date in the filename; using its mtime {1})" -f (Split-Path $f -Leaf), $sd.ToString('yyyy-MM-dd'))
  }
  $ageD = [int]($buildDate - $sd).TotalDays
  if ($ageD -gt $MaxExtractDays) {
    $agedOut += ("{0} ({1} days old)" -f (Split-Path $f -Leaf), $ageD)
    continue
  }
  $srcDates[$f] = $sd.ToString('yyyy-MM-dd')
  $keptIn.Add($f)
}
$In = @($keptIn.ToArray())

foreach ($f in $In) {
  if (-not (Test-Path $f)) { continue }
  $srcAsOf = if ($srcDates.ContainsKey($f)) { $srcDates[$f] } else { $asofS }
  foreach ($r in (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json)) {
  # The storefront capture is UTF-8; reading it under the system ANSI codepage turned brand names into
  # mojibake that then shipped to the board ("Mott(junk)s", "Saran(junk)"). Repair on ingest - see capture-lib.
  if ($r.PSObject.Properties['name']) { $r.name = Repair-Mojibake ([string]$r.name) }
    $id = [string]$r.id
    if (-not $validSet.ContainsKey($id)) { continue }
    $name = [string]$r.name
    if (-not $name -or $name -match 'NOT FOUND') { continue }
    # Fareway's capture writes price either bare ("5.39") or already-signed ("$5.39"); every branch below
    # prefixes '$', so the signed form shipped "$$5.39" to the board (mirin + chipotle-adobo chips, 2026-07-28).
    # Strip the sign once here so there is exactly one, whatever the capture handed us.
    $price = ([string]$r.price).Trim().TrimStart('$'); if (-not $price) { continue }
    $per = ([string]$r.per).ToLower()
    $unit = [string]$r.unit
    $size = [string]$r.size
    $adp = ''; $sz = ''
    $um = [regex]::Match($unit, '\$?\s*([\d.]+)\s*/\s*(lb|oz|gal|kg|ct|ea|each|pound)')
    if ($um.Success) {
      $adp = '$' + $um.Groups[1].Value
      $u = $um.Groups[2].Value; if ($u -eq 'pound') { $u = 'lb' }; if ($u -eq 'ea') { $u = 'each' }
      $sz = $u
    } elseif ($per -eq 'pound') { $adp = '$' + $price; $sz = 'lb' }
      elseif ($per -eq 'each')  { $adp = '$' + $price; $sz = 'each' }
      else { $adp = '$' + $price; $sz = $size }
    # SLUG BASIS OVERRIDE (2026-07-23): Fareway's catalog slug names the sell basis for by-weight
    # produce - ".../products/16606119-cantaloupe-melon-1-lb" is priced PER POUND even when the tile's
    # DOM says "each". Trusting the DOM published $0.88 as the price of a WHOLE melon (real price
    # ~3x that); the band caught it and Fareway just vanished from the row. The slug is the catalog's
    # own statement of basis, so it outranks the tile text.
    if ($r.url -and "$($r.url)" -match '(?i)-1-lb(?:-|$)' -and $sz -eq 'each') { $sz = 'lb' }
    # ---- slug-size derivation + conflict quarantine (2026-08-01, triage 9da3a8; see the header block) ----
    $slugSz = Get-SlugSize ([string]$r.url) $name
    $capSz  = Get-CapturedMeasure $size
    # refusal 4: the capture and the catalog each state a size and they disagree by 1.5x or more.
    # NARROWED after measurement (2026-08-01). The rule as first written dropped SIX rows, not the two the
    # triage plan measured, and four of the six were the slug being wrong about a perfectly good capture:
    #   Glade air freshener  capture 7.3 oz  vs slug "73-oz"   - the decimal point fell out of the slug
    #   Fareway 2% milk      capture 0.5 gal vs slug "05-gal"  - same, with a leading zero (now refused above)
    #   Jimmy Dean sandwiches capture 18 oz  vs slug "4-5-oz"  - the slug names ONE of the "4 Count" sandwiches
    #   Pero sugar snap peas capture 8 oz    vs slug "15-oz"   - a stale/wrong slug, capture is the priced surface
    # So the quarantine is now scoped to the failure it was actually built for: a CAPTURED size inflated far
    # beyond the catalog's, which is the shape of both documented corruptions (Softsoap 221 fl oz against a
    # 7.5 oz pump, Hawaiian Punch 512 fl oz against a 1 gal jug) and which silently sinks the per-unit below
    # the band. Three ways out, in order:
    #   a. the slug is the SAME number with the decimal dropped -> they agree, publish the capture
    #   b. the slug is one unit of a pack whose count the NAME states -> they agree, publish the capture
    #   c. the SLUG is the larger side -> the slug is wrong, not the capture; the band still judges the row
    # The captured size is the surface the PRICE was read from. Deleting it on the word of a source we have
    # now caught being wrong in three distinct ways would cost real cells to buy no accuracy.
    if ($slugSz -and $slugSz.ok -and $capSz -and ($slugSz.family -eq $capSz.family)) {
      $capOz = [double]$capSz.ozEquiv; $slugOz = [double]$slugSz.ozEquiv
      $reconciled = $false
      if ((('{0:0.####}' -f $capSz.n) -replace '\.', '') -eq [string]$slugSz.raw) { $reconciled = $true }   # (a)
      if (-not $reconciled -and $capOz -gt 0) {                                                             # (b)
        foreach ($packM in [regex]::Matches($name, '(?i)(\d+)\s*(?:ct\b|count\b|pack\b|pk\b)')) {
          $packN = [double]$packM.Groups[1].Value
          if ($packN -gt 1 -and $slugOz -gt 0 -and (([Math]::Abs($capOz - ($slugOz * $packN))) / $capOz) -le 0.05) { $reconciled = $true; break }
        }
      }
      if (-not $reconciled -and $slugOz -gt 0 -and ($capOz / $slugOz) -ge 1.5) {                             # (c) direction
        $basisConflicts++
        $basisConflictIds += ("$id (" + $name + ": capture says '" + $size + "', catalog slug says '" + $slugSz.text + "')")
        continue
      }
    }
    # A count the CAPTURE already carries ("28 each", "120 each") must survive the each-unit fixup below,
    # which only ever recognised the literal token "ct" - which is why Fareway's trash bags and dryer sheets
    # published as one item. N=1 is deliberately left alone: "1 each" and "each" mean the same thing, and
    # rewriting it would churn ~60 correct produce rows to say the same thing differently.
    $countSize = ''
    if ($capSz -and $capSz.family -eq 'count' -and $capSz.n -gt 1) { $countSize = ('{0:0.####} ct' -f $capSz.n) }
    # refusal 1 + adoption: the slug is the fallback ONLY when the capture stated no usable size at all.
    if (($name -notmatch '(?i)-\s*pack\s*$') -and $slugSz -and $slugSz.ok -and $slugSz.adoptable -and ($sz -eq '' -or $sz -eq 'each' -or $sz -eq 'ea')) {
      $sz = $slugSz.text
      if ($slugSz.family -eq 'count' -and $slugSz.n -gt 1) { $countSize = $slugSz.text }
    }
    # Did anything above establish a WEIGHT basis for this row? Either the tile's own unit rate ("$1.49/lb"),
    # or the catalog slug. Both are the store stating that the price is per pound, not per item.
    $weightBasis = ($sz -match '^(lb|oz|kg)$')
    # canonical-unit fixups so the engine can price the item in the commodity's unit
    $cu = if ($unitMap.ContainsKey($id)) { $unitMap[$id] } else { '' }
    # A PER-POUND RATE MUST NEVER BE RELABELLED AS A PER-ITEM PRICE (2026-07-30).
    # The $cu -eq 'each' branch below rewrites $sz to 'each' while KEEPING whatever $adp was parsed. When the
    # tile stated a weight rate, $adp is that rate, and the rewrite silently turns "$1.49 per pound" into
    # "$1.49 for one item". Honeydew is the live case: Fareway's capture reads price=5.96, per=package,
    # unit=$1.49/lb, size="About 4.0 lb / package", url=.../17668522-honeydew-melon-1-lb. Every one of those
    # says four pounds for $5.96. The board published $1.49 EACH, took the CROWN from Baker's genuine $2.99
    # each, was written up with the store's own arithmetic on 2026-07-29, and was still the published cheapest
    # price the day after.
    # The fix is NOT to pick a winner between the two bases, and NOT to compute $5.96 x something here: the
    # capture's own package price is right there, but re-deriving a published number from a plausible reading
    # is the blind-swap trap that has twice removed correct data in this repo. Two statements of basis
    # disagree, so the honest output is no number. The row is dropped and NAMED - a missing cell is visible on
    # the page and a wrong crown is not.
    # A counted pack ("12 ct") is NOT a conflict: the count is the quantity, not a weight claim.
    if ($weightBasis -and $cu -eq 'each' -and $size -notmatch '\d+\s*ct\b') {
      $basisConflicts++
      $basisConflictIds += ("$id (" + $name + ")")
      continue
    }
    if ($cu -eq 'each') {
      # a loaf / avocado / ear / whole melon = one each; the current price IS the per-each price.
      # BUT a counted pack ("12 ct" buns/popsicles/tampons) must KEEP its count so the engine divides
      # to a true per-item price - force-writing 'each' here made $3.99/12ct read as $3.99 PER ITEM.
      if ($countSize) { $sz = $countSize }
      elseif ($size -match '\d+\s*ct\b') { $sz = $size }
      elseif ($slugSz -and $slugSz.ok -and $slugSz.family -eq 'count' -and [double]$slugSz.n -gt 1 -and ($name -notmatch '(?i)-\s*pack\s*$')) {
        # The capture stated a WEIGHT for a commodity priced per ITEM ("Fareway All Butter Croissants",
        # 8.5 oz) - true, and useless, because a weight cannot divide into a per-item price, so the row
        # published as "$5.99 each" for a bag of three. The catalog slug states the count ("...-3-ct").
        # Measured 2026-08-01 over all four Fareway captures: exactly 2 rows reach this branch, croissants
        # (3 ct -> $2.00 each) and Sunbelt granola bars (10 ea -> $0.288 each), both named in the triage plan.
        $sz = $slugSz.text
      }
      else { $sz = 'each' }
      if ($adp -notmatch '^\$[0-9.]+$') { $adp = '$' + $price }
    } elseif ($cu -eq 'gallon') {
      # A REAL VOLUME IN THE CAPTURE OUTRANKS THE CANONICAL RELABEL (2026-08-01, found while implementing
      # triage 9da3a8). This branch used to write size='gallon' unconditionally while KEEPING the pack price,
      # which is the same defect the each-branch above was fixed for on 2026-07-30, two lines further up.
      # Live case: Fareway 2% Reduced Fat Milk captures price=3.15 size='0.5 gal' (and its slug says
      # "...-05-gal"), and the board published "$3.15 per GALLON" - half the real per-gallon price of $6.30,
      # on the milk row, 4th cheapest of seven. When the capture states a volume, keep it and let the engine
      # divide; only relabel when there is no usable volume to keep.
      $volNow = Get-CapturedMeasure $sz
      if (-not ($volNow -and $volNow.family -eq 'measure')) { $sz = 'gallon' }
    }
      elseif ($cu -eq 'dozen') {
        # Same shape, opposite direction. "Dutch Farms 18 Grade A Large Eggs" captures price=2.17 with
        # size='36 oz' - a WEIGHT, so the 'ct' match below found nothing and the row published as $2.17 per
        # DOZEN, making Fareway the dearest eggs on the board when 18 eggs for $2.17 is $1.45 a dozen and the
        # second cheapest. The count is right there in the catalog slug ("...-18-ct"), so read it.
        $ct = [regex]::Match($size, '([\d.]+)\s*ct')
        $eggN = 0.0
        if ($ct.Success) { $eggN = [double]$ct.Groups[1].Value }
        elseif ($slugSz -and $slugSz.ok -and $slugSz.family -eq 'count' -and [double]$slugSz.n -gt 1) { $eggN = [double]$slugSz.n }
        if ($eggN -gt 0) { $adp = '$' + ([math]::Round([double]$price / ($eggN/12), 2)) }
        $sz = 'dozen'
      }
    # by-VOLUME container -> canonical dry weight: a fresh-berry "pint" is a dry clamshell with no weight on the
    # label, so normalize it to the commodity's declared pint_oz (blueberries = 11.2 oz, US retail standard). This
    # makes BOTH the board price and the "See item" link size a real weight, so it prices per-ounce like the
    # 18-oz clamshells and the link's per-unit matches the board by construction. Only bare pints, never a size
    # that already states a weight.
    if ($pintMap.ContainsKey($id) -and ($sz.ToLower() -match '\b(pt|pint)s?\b') -and ($sz.ToLower() -notmatch '\b(oz|ounce|ounces|lb|lbs|pound|pounds|gram|grams|\bg\b|ml|liter|litre)\b')) {
      $pnM = [regex]::Match($sz.ToLower(), '(\d+(?:\.\d+)?)\s*(?:pt|pint)s?\b'); $pn = if ($pnM.Success) { [double]$pnM.Groups[1].Value } else { 1 }
      $sz = ('{0} oz' -f ($pn * $pintMap[$id]))
    }
    $reg = if ($r.orig -and "$($r.orig)" -ne '') { '$' + ([string]$r.orig).Trim().TrimStart('$') } else { '' }

    # THE CONTRACT (guards invariant 10): record what the STORE CHARGES, separately from what we publish.
    # `current_price` is parsed from the number the storefront is showing right now, in the SAME basis as
    # ad_price (per-lb for weighted goods, pack price for packaged). ad_price is built from that same store
    # number - but as a SEPARATE assignment, which is the whole point: if anyone ever rewires ad_price to
    # publish `orig` (the was-price) instead, the two stop agreeing and guard 10 fails the publish. That is
    # exactly the bug that had Hy-Vee sirloin at $13.99/lb while the store charged $11.99.
    $curNum = 0.0
    [void][double]::TryParse(($adp -replace '[^0-9.]',''), [ref]$curNum)
    $row = [ordered]@{ store='Fareway'; item=$name; ad_price=$adp; size=$sz; regular=$reg; source_ad='shop.fareway.com'; as_of=$srcAsOf; found_by_term=[string]$r.term }
    # identity rule: the link belongs ON the price row (derive-links reads link_url verbatim), not only in
    # the url-inputs side file - two homes for one fact is how they drift.
    if ($r.url -and "$($r.url)" -ne '') { $row['link_url'] = [string]$r.url }
    if ($r.taxonomy_path) { $row['taxonomy_path'] = [string]$r.taxonomy_path }
    if ($curNum -gt 0) { $row['current_price'] = $curNum }

    # base_price (the was-price) ONLY when it is in the same basis as what we publish. For a weighted good we
    # publish a per-POUND price while `orig` is the PACK's was-price - recording that as base_price would be
    # comparing a per-lb number to a per-pack one, which is how you end up "verifying" nonsense.
    $origNum = 0.0
    [void][double]::TryParse((([string]$r.orig) -replace '[^0-9.]',''), [ref]$origNum)
    if (($origNum -gt 0) -and ($sz -ne 'lb')) { $row['base_price'] = $origNum }
    if (($origNum -gt 0) -and ($sz -ne 'lb') -and ($curNum -lt ($origNum - 0.005))) { $row['marked_down'] = $true }

    $byId[$id] = $row
    # emit the product-URL input using the SAME price+size the board uses, so the "See item" link's per-unit
    # equals the board per-unit by construction (a Fareway price can never render without a matching link).
    if ($r.url -and "$($r.url)" -ne '') { $byUrl[$id] = [ordered]@{ id=$id; url=[string]$r.url; price=($adp -replace '[^0-9.]',''); size=$sz; name=$name } }
  }
}
$deals = @($byId.Values)
# price_mode/mode_verified come from the CAPTURE, not an assumption here.
# Fareway is an Instacart storefront whose DEFAULT session serves a marked-up DELIVERY price. This script used to
# hard-code price_mode='in-store' to satisfy audit-price-mode - which DEFEATED the guard: on 2026-07-15 the whole
# storefront extract was found to be delivery-priced (butter +14%, cream cheese +50%, OJ +37%) yet stamped
# in-store, putting 320 marked-up cells on the board. FIX: only claim in-store when the browser capture PROVES it
# by passing -ModeVerified <yyyy-MM-dd> (it set the In-Store fulfilment toggle and confirmed it that day). With no
# proof we emit price_mode='unverified' (no mode_verified) so audit-price-mode fails AND compare-deals drops the
# file - the marked-up prices can never silently reach the board again.
$pmode = if ($ModeVerified) { 'in-store' } else { 'unverified' }
$doc = [ordered]@{ store='Fareway'; price_type='everyday'; price_mode=$pmode; mode_verified=$ModeVerified; source='shop.fareway.com (Instacart Storefront, Omaha); mode proven at capture only'; generated=$asofS; deals=$deals }
if (-not $ModeVerified) { Write-Warning "build-fareway-regular: no -ModeVerified passed -> price_mode='unverified'. The capture MUST set In-Store fulfilment and pass -ModeVerified <date>, or Fareway is (correctly) excluded from the board." }
$regDir = Join-Path $OutDir 'regular'
New-Item -ItemType Directory -Force -Path $regDir | Out-Null
# NEVER-SHRINK GUARD (2026-07-17, same rule as the Family Fare throttle-wipeout guard). The regular file can
# hold MORE rows than any one shop capture: walled-store passes accumulate verified rows into it that a rebuild
# from shop files alone cannot reproduce (382 verified rows vs 89 in the newest shop file, the day this nearly
# overwrote them). Replacing a bigger file with a smaller one is a partial-pull-as-overwrite bug, not a refresh.
$regPath = Join-Path $regDir "fareway-regular-$asofS.json"
if (Test-Path $regPath) {
  $old = $null; try { $old = Get-Content $regPath -Raw | ConvertFrom-Json } catch {}
  if ($old -and (@($old.deals).Count -gt ($deals.Count * 1.2)) -and -not $Force) {
    throw ("REFUSING to overwrite " + (Split-Path $regPath -Leaf) + ": it holds " + @($old.deals).Count + " rows, this rebuild produced only " + $deals.Count + ". That file accumulated verified rows a shop-file rebuild cannot reproduce. Pass -Force only if the shrink is intended.")
  }
}
$doc | ConvertTo-Json -Depth 5 | Set-Content $regPath -Encoding UTF8
# product-URL input for merge-product-urls.ps1 (store key 'fareway'): every priced Fareway cell that has a
# storefront product page gets a link whose price+size match the board exactly.
$urlRows = @($byUrl.Values)
if ($urlRows.Count) {
  $uiDir = Join-Path $OutDir 'url-inputs'; New-Item -ItemType Directory -Force -Path $uiDir | Out-Null
  ($urlRows | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $uiDir 'store-fareway1-urls.json') -Encoding UTF8
  Write-Output ("store-fareway1-urls.json: $($urlRows.Count) Fareway product links")
}
Write-Output ("fareway-regular-$asofS.json: $($deals.Count) commodities")
# Say out loud how much of this file is actually today's price. The whole point of the dating fix is that
# this number can now be wrong in the direction that gets noticed, instead of always reading 100%.
$freshN = @($deals | Where-Object { ([string]$_.as_of) -eq $asofS }).Count
$dateMix = @($deals | Group-Object { [string]$_.as_of } | Sort-Object Name -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '  '
Write-Output ("  as_of: $freshN of $($deals.Count) row(s) priced from TODAY's extract   [$dateMix]")
if ($agedOut.Count -gt 0) {
  Write-Output ("  AGED OUT - skipped $($agedOut.Count) extract(s) older than $MaxExtractDays days, so any commodity carried only by them has no Fareway cell today (absent by decision, not by accident): " + ($agedOut -join ', '))
}
if ($undatedSrc.Count -gt 0) {
  Write-Output ("  UNDATED SOURCE - $($undatedSrc.Count) extract(s) carry no date in the filename; their rows are dated from the file's mtime, which is a weaker claim than a capture date: " + ($undatedSrc -join ', '))
}
if ($basisConflicts -gt 0) {
  Write-Output ("  BASIS CONFLICT - dropped $basisConflicts row(s): the catalog slug says per-pound but the commodity is priced per-each, so the price could mean either a pound or a whole item. No number is honest here; these cells are absent by decision, not by accident: " + (($basisConflictIds | Sort-Object -Unique) -join ', '))
}
$deals | ForEach-Object { "  {0,-20} {1,-8} {2}" -f $_.item.Substring(0,[Math]::Min(20,$_.item.Length)), $_.ad_price, $_.size }
# 2026-07-23: a partial storefront pull must not shrink the board - carry items the previous capture had
# and this one missed (as_of-stamped, 14-day cap). See carry-forward-regular.ps1 for why these stores
# can't use the Walmart/Sam's union instead.
if (-not $NoCarry) {
& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'carry-forward-regular.ps1') -Store fareway | Write-Output
# 2026-07-23: a shallow pull can also DEGRADE rows it does return - same item, same shelf price, but the
# pack count gone from the size field ("48 ct" -> "each"). The per-unit engine then computes a per-item
# price 48x too high and the band drops the store from the row. Re-adopt the prior capture's size when
# item AND price are identical. See heal-degraded-sizes.ps1.
& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'heal-degraded-sizes.ps1') -Store fareway | Write-Output
# 2026-08-02: the two steps above copy rows out of PRIOR regular files, and every file built before today
# carries laundered as_of dates - so carry-forward faithfully preserves a date that was never measured.
# This re-dates such a row DOWN to the newest capture that actually holds it and drops it if that honest
# date is past the window. Runs LAST because it has to see what carry-forward and the size-heal wrote.
& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'repair-asof-evidence.ps1') -Store fareway -MaxAgeDays $MaxExtractDays | Write-Output
}

