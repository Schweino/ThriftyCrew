<#
  build-aldi-regular.ps1 - turn a RAW aldi.us browser capture into out\regular\aldi-regular-<date>.json.

  WHY THIS EXISTS. Aldi was the last priced store whose everyday file was hand-assembled in the agent's head
  each week. Every other store has a builder (build-walmart-deals, build-sams-deals, build-fareway-regular)
  precisely because hand-assembly is where the unit-basis bugs get in: a per-lb rate written into a package
  size, a pack count left in the NAME so the engine re-divides, a card price captured without its href so the
  tile ships a price with no "See item". This does the same job for Aldi, once, in code.

  Input CSV (pipe-delimited, from the storefront SPA sweep):  id|term|name|prices|unit|size|href
     id     = the commodity id the search term came from (audit only - matching stays engine-side)
     name   = the product-URL SLUG, de-hyphenated. The slug is Aldi's own name for the item and it carries the
              pack size ("goldhen grade a large eggs 12 ct"). Card TEXT is not used for the name: on the
              Instacart-storefront platform the longest card line is often a descriptor ("Sold individually",
              "Produce") - the defect that silently dropped 82 Fareway rows on 2026-07-27.
     prices = every "$n.nn" the card rendered, space-joined. FIRST is the price you pay.
     unit   = a "$n.nn/lb"-style unit price when the card showed one (weighted goods), else blank
     size   = the size token the card printed, else blank -> fall back to the name

  UNIT BASIS (the rule every feed must agree on, from the SKILL):
     weighted (unit carries /lb)  -> ad_price = the per-lb dollar, size = bare "lb"
     packaged                     -> ad_price = the PACKAGE price,  size = the package size ("16 oz")
     milk                         -> "1 gal" / "0.5 gal";  eggs -> "dozen" (a "12 ct" name becomes "dozen")
  A row whose size cannot be established is REJECTED, not guessed - an unsized row is what lets the engine
  divide a package price by nothing and crown a phantom cheapest.

  Usage: .\build-aldi-regular.ps1 -In out\captures\aldi-capture-2026-07-29.csv -Date 2026-07-29
         .\build-aldi-regular.ps1 -SelfTest
#>
param(
  [string]$In = "",
  [string]$Date = "",
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\income\grocery' }
. (Join-Path $root 'capture-lib.ps1')   # UTF-8 capture read + mojibake repair, shared by every builder

# Words that mean "this tile is not the plain commodity". Kept deliberately small: compare-deals owns the real
# include/exclude per commodity. This only drops things that are never the base item at any store.
$SKIP_NAME = '(?i)\b(gift ?card|recipe|bundle|subscription)\b'

function Convert-Name([string]$slug) {
  $s = ($slug -replace '\s+', ' ').Trim()
  if (-not $s) { return '' }
  # Title-case, but leave unit tokens and percentages alone ("12 ct", "80%").
  $parts = $s -split ' '
  $out = foreach ($p in $parts) {
    if ($p -match '^\d') { $p }
    elseif ($p.Length -le 2) { $p.ToUpper() }
    else { $p.Substring(0,1).ToUpper() + $p.Substring(1) }
  }
  ($out -join ' ')
}

function Repair-SlugDecimals([string]$name, [string]$cardSize) {
  # Aldi's product URL is the only reliable source for the item NAME (card text hands back descriptors like
  # "Sold individually"), but a URL slug cannot hold a period: "15.25 oz" ships as ".../-15-25-oz" and
  # de-hyphenating it yields "15 25 oz". 575 of 3041 rows on 2026-07-29 came through with a name like that.
  # The size itself survives (the card prints "15.25 oz" and Get-Size prefers it), so the PRICE was never
  # wrong - but the engine reads PACK COUNTS out of the item name, and "original bratwurst 45 6 oz" offers it
  # a "45" to read as a pack. So splice the decimal back in, using the card's own size as the proof. No card
  # size, no repair - a plausible-looking decimal is still a guess.
  if (-not $cardSize) { return $name }
  $cs = [regex]::Match($cardSize, '(?i)\b(\d+)\.(\d+)\s*(fl\s*oz|floz|oz|lb|lbs|gal|ct|count|qt|pt|liter|ml)\b')
  if (-not $cs.Success) { return $name }
  $whole = $cs.Groups[1].Value; $frac = $cs.Groups[2].Value
  # only rewrite when the name really does carry those exact digits split by a space
  $pat = '\b' + [regex]::Escape($whole) + '\s+' + [regex]::Escape($frac) + '\b'
  if ($name -notmatch $pat) { return $name }
  return ([regex]::Replace($name, $pat, ($whole + '.' + $frac), 1))
}

function Get-Size([string]$name, [string]$cardSize, [string]$unit) {
  # 1) weighted goods: the unit price is per pound, so the basis IS the pound
  if ($unit -match '(?i)/\s*lb') { return 'lb' }

  # 1b) MULTIPACK: the pack COUNT only ever appears in the name, while the storefront card shows the size of
  # ONE unit ("Maruchan Ramen 6 PK 13.5 OZ" -> card says 2.25 oz; "Gatorade 18 Pack 12 FL OZ" -> card 12 fl oz).
  # Preferring the card blindly records one unit as the whole pack, which is guards.ps1 hard-fail #5 (the Sam's
  # 2-pack bug) - it shipped 3 Aldi rows on 2026-07-29 and blocked the daily publish. So when the NAME states a
  # pack count, emit the engine's "N pk M unit" form, which multiplies them back into the pack total.
  $pk = [regex]::Match($name, '(?i)\b(\d+)\s*(?:pk|pack)\b')
  if ($pk.Success -and [int]$pk.Groups[1].Value -gt 1 -and $cardSize) {
    $one = [regex]::Match($cardSize, '(?i)^\s*(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|lb|lbs|ml|liter|qt|pt)\b')
    if ($one.Success) {
      $u = ($one.Groups[2].Value.ToLower() -replace '\s+', ' ') -replace '^floz$', 'fl oz'
      if ($u -eq 'lbs') { $u = 'lb' }
      return ($pk.Groups[1].Value + ' pk ' + $one.Groups[1].Value + ' ' + $u)
    }
  }

  # The card size wins ONLY if it actually states a measure. A wrapped record leaves junk in this field (the
  # split price text: "449" + newline + "L"), and a bare `if ($cardSize)` handed that junk to every scan below,
  # which found no unit and returned '' - so the NAME, which says "14 oz" right there, was never consulted.
  # That silently rejected 42 rows as "no size", including Aldi's entire L'oven Fresh bread lineup.
  $hasMeasure = $cardSize -match '(?i)\d\s*(fl\s*oz|floz|oz|ounces?|lbs?|pounds?|qt|quarts?|pt|pints?|liters?|litres?|ml|gal|gallons?|ct|count|pk|pack|dozen)\b'
  $hay = if ($cardSize -and $hasMeasure) { $cardSize } else { $name }

  # 1c) BARE "oz" ON A LIQUID: the card wins over the name (above), but the card states only a MAGNITUDE - it
  # drops the "fl". "Sundae Shoppe Vanilla Light Ice Cream, 1 Gal" carded as "128 oz" published a real $6.39
  # gallon as a WEIGHT cell on a volume-priced row, and took the Ice Cream crown while measured in a different
  # currency than every peer (guards.ps1 hard-fail, audit-unit-basis-outlier 2026-08-15). The number was right
  # the whole time; only its KIND was wrong, which is why no price guard could see it.
  # Relabel ONLY on arithmetic agreement: the NAME must state an explicit volume whose fl-oz value EQUALS the
  # card's bare-oz number. That equality is the proof - a genuine weight-oz row (a 1 pt tomato package carded
  # "10 oz") never satisfies it, so this cannot invent a volume where the item really is sold by weight.
  if ($cardSize -and $hasMeasure -and $hay -match '(?i)^\s*(\d+(?:\.\d+)?)\s*(?:oz|ounces?)\s*$') {
    $cardOz = [double]$Matches[1]
    $volFlOz = 0.0
    $nv = [regex]::Match($name, '(?i)(\d+(?:\.\d+)?)\s*(gal|gallons?|qt|quarts?|pt|pints?)\b')
    if ($nv.Success) {
      $volFlOz = switch -Regex ($nv.Groups[2].Value.ToLower()) {
        '^gal'  { [double]$nv.Groups[1].Value * 128 }
        '^qt'   { [double]$nv.Groups[1].Value * 32 }
        '^pt'   { [double]$nv.Groups[1].Value * 16 }
        default { 0.0 }
      }
    }
    elseif ($name -match '(?i)\bhalf\s*gal') { $volFlOz = 64.0 }
    if ($volFlOz -gt 0 -and [math]::Abs($cardOz - $volFlOz) -lt 0.01) {
      return ('{0} fl oz' -f $volFlOz)
    }
  }

  # REFUSE TO GUESS A SLUG-COLLAPSED DECIMAL. Aldi names come from URL slugs, which cannot hold a '.', so
  # "10.4 OZ" arrives as "10 4 OZ". Repair-SlugDecimals fixes it only when the card size independently proves
  # the digits; when it cannot, reading the trailing number alone gives 4 oz for a 10.4 oz item - a 2.6x error
  # in the CHEAP direction, which is exactly the shape that crowns a false cheapest store. Two bare integers
  # in front of a unit means the decimal is lost, so drop the cell. Guessing here is worse than no cell.
  # ('6 pk 13.5 oz' and '12 pk 12 fl oz' are unaffected - they carry a pack word between the numbers.)
  if (-not ($cardSize -and $hasMeasure)) {
    if ($hay -match '(?i)\b\d+\s+\d+(?:\.\d+)?\s*(fl\s*oz|floz|oz|ounces?|lbs?|pounds?|ct|count)\b') { return '' }
  }

  # 2) milk / liquid gallons - normalise before the generic scan so "1 gal" doesn't read as a count
  $g = [regex]::Match($hay, '(?i)(\d+(?:\.\d+)?)\s*(?:gal|gallon)s?\b')
  if ($g.Success) { return ($g.Groups[1].Value + ' gal') }
  if ($hay -match '(?i)\bhalf\s*gal') { return '0.5 gal' }

  # 3) eggs: a dozen is a dozen however the slug spells it
  if ($name -match '(?i)\begg' -and $name -notmatch '(?i)\b(noodle|roll|substitute|white)s?\b') {
    $c = [regex]::Match($hay, '(?i)(\d+)\s*(?:ct|count|pk|pack)\b')
    if ($c.Success) {
      $n = [int]$c.Groups[1].Value
      if ($n -eq 12) { return 'dozen' }
      return ("$n ct")
    }
    if ($hay -match '(?i)\bdozen\b') { return 'dozen' }
  }

  # 4) multipack stated as "12 pk 12 fl oz" / "4-15 oz" -> keep BOTH numbers, the engine multiplies them
  $mp = [regex]::Match($hay, '(?i)(\d+)\s*(?:pk|pack|ct|count)\D{0,6}(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|lb|lbs)\b')
  if ($mp.Success) {
    $u = ($mp.Groups[3].Value.ToLower() -replace '\s+', ' ') -replace '^floz$', 'fl oz'
    return ($mp.Groups[1].Value + ' pk ' + $mp.Groups[2].Value + ' ' + $u)
  }
  $dash = [regex]::Match($hay, '(?i)(\d+)\s*-\s*(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|lb|lbs)\b')
  if ($dash.Success) {
    $u = ($dash.Groups[3].Value.ToLower() -replace '\s+', ' ') -replace '^floz$', 'fl oz'
    return ($dash.Groups[1].Value + ' pk ' + $dash.Groups[2].Value + ' ' + $u)
  }

  # 5) plain weight / volume
  $w = [regex]::Match($hay, '(?i)(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|ounce|ounces|lb|lbs|pound|pounds|qt|quart|pt|pint|liter|litre|ml)\b')
  if ($w.Success) {
    $u = $w.Groups[2].Value.ToLower()
    switch -regex ($u) {
      '^(floz|fl\s*oz)$'      { $u = 'fl oz' }
      '^(ounce|ounces)$'      { $u = 'oz' }
      '^(lbs|pound|pounds)$'  { $u = 'lb' }
      '^(quart)$'             { $u = 'qt' }
      '^(pint)$'              { $u = 'pt' }
      '^(litre)$'             { $u = 'liter' }
    }
    return ($w.Groups[1].Value + ' ' + $u)
  }

  # 6) a bare count ("12 ct", "8 pack")
  $c2 = [regex]::Match($hay, '(?i)(\d+)\s*(?:ct|count|pk|pack)\b')
  if ($c2.Success) { return ($c2.Groups[1].Value + ' ct') }

  # 7) explicitly sold as one unit
  if ($hay -match '(?i)\b(each|ea)\b') { return 'each' }
  return ''
}

function Invoke-Build([object[]]$raw, [string]$date) {
  $rows = New-Object System.Collections.ArrayList
  $seen = @{}
  $rejects = New-Object System.Collections.ArrayList
  foreach ($r in $raw) {
    $name = Convert-Name (Repair-SlugDecimals ([string]$r.name) ([string]$r.size))
    if (-not $name) { [void]$rejects.Add([pscustomobject]@{ item = [string]$r.name; why = 'no name' }); continue }
    if ($name -match $SKIP_NAME) { [void]$rejects.Add([pscustomobject]@{ item = $name; why = 'not a grocery item' }); continue }

    $pm = [regex]::Match([string]$r.prices, '\$(\d+(?:\.\d+)?)')
    if (-not $pm.Success) { [void]$rejects.Add([pscustomobject]@{ item = $name; why = 'no price' }); continue }
    $price = [double]$pm.Groups[1].Value
    if ($price -le 0) { [void]$rejects.Add([pscustomobject]@{ item = $name; why = 'zero price' }); continue }

    $unit = [string]$r.unit
    # A weighted tile prints BOTH an estimated package price and a $/lb. The board wants the $/lb.
    if ($unit -match '(?i)\$\s*(\d+(?:\.\d+)?)\s*/\s*lb') { $price = [double]$Matches[1] }

    $size = Get-Size $name ([string]$r.size) $unit
    if (-not $size) { [void]$rejects.Add([pscustomobject]@{ item = $name; why = 'no size' }); continue }

    $key = ($name + '|' + $size).ToLower()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true

    $row = [ordered]@{
      store         = 'Aldi'
      item          = $name
      ad_price      = ('$' + $price)
      size          = $size
      regular       = $null
      current_price = $price
      source_ad     = 'everyday shelf price'
      price_type    = 'everyday'
      as_of         = $date
      found_by_term = [string]$r.term
    }
    $u = [string]$r.href
    if ($u -match '^https?://') { $row['link_url'] = $u }
    if ($r.taxonomy_path) { $row['taxonomy_path'] = [string]$r.taxonomy_path }
    [void]$rows.Add([pscustomobject]$row)
  }
  return @{ rows = $rows.ToArray(); rejects = $rejects.ToArray() }
}

function Join-WrappedRecords {
  <#
    Rejoin records the browser capture split across lines. A card's innerText can swallow the newline after a
    size token, writing a literal line break INSIDE a field, so one 7-field record arrives as a 5-pipe HEAD
    plus a 1-pipe TAIL.

    THE TRAP (shipped 2026-07-29, caught the same day): the first version tested each line in isolation and
    glued anything with fewer than 6 pipes onto the previous line. Both halves of a wrapped record are under
    6, so BOTH got glued onto the previous, already-complete record - it ate 31 real records (Aldi's whole
    store-brand bread lineup) and left 12 link_urls carrying the next record's search term after a space, one
    of which reached product-urls.json. A "fix" that recovered 27 rows net -27.

    So: accumulate until the BUFFER reaches 6 pipes, and never absorb a line that is itself a complete record
    (>= 6 pipes) - an incomplete buffer followed by a whole record means the capture dropped a fragment, and
    dropping one damaged row beats swallowing a good one.
  #>
  param([string[]]$Lines)
  $out = New-Object System.Collections.ArrayList
  $buf = $null
  $rejoined = 0
  $orphans = 0
  foreach ($ln in $Lines) {
    $lnPipes = ([regex]::Matches([string]$ln, '\|')).Count
    if ($null -ne $buf) {
      if ($lnPipes -ge 6) {
        [void]$out.Add($buf); $buf = $null; $orphans++     # keep the fragment, keep the whole record
        [void]$out.Add([string]$ln)
        continue
      }
      $buf = $buf + ' ' + ([string]$ln).Trim(); $rejoined++
      if (([regex]::Matches($buf, '\|')).Count -ge 6) { [void]$out.Add($buf); $buf = $null }
      continue
    }
    if ($lnPipes -ge 6) { [void]$out.Add([string]$ln) } else { $buf = [string]$ln }
  }
  if ($null -ne $buf) { [void]$out.Add($buf); $orphans++ }
  return @{ lines = $out.ToArray(); rejoined = $rejoined; orphans = $orphans }
}

if ($SelfTest) {
  $cases = @(
    @{ n = 'goldhen grade a large eggs 12 ct';            s = '12 ct';  u = '';          want = 'dozen' }
    @{ n = 'friendly farms whole milk 1 gal';             s = '1 gal';  u = '';          want = '1 gal' }
    @{ n = 'appleton farms bacon 16 oz';                  s = '16 oz';  u = '';          want = '16 oz' }
    @{ n = 'fresh ground beef';                           s = '';       u = '$3.99/lb';  want = 'lb' }
    @{ n = 'purified water 24 pk 16.9 fl oz';             s = '';       u = '';          want = '24 pk 16.9 fl oz' }
    @{ n = 'countryside creamery butter quarters 16 oz';  s = '';       u = '';          want = '16 oz' }
    @{ n = 'mystery item with no size at all';            s = '';       u = '';          want = '' }
    # guards.ps1 hard-fail #5: a NAME saying "N pack" must never record ONE unit as the size
    @{ n = 'maruchan ramen noodle soup chicken 6 pk 13.5 oz'; s = '2.25 oz';  u = ''; want = '6 pk 2.25 oz' }
    @{ n = 'gatorade thirst quencher 18 pack 12 fl oz';       s = '12 fl oz'; u = ''; want = '18 pk 12 fl oz' }
    @{ n = 'breakfast best breakfast pizza 2pk 11.2 oz';      s = '11.2 oz';  u = ''; want = '2 pk 11.2 oz' }
    @{ n = 'single item 1 pk 16 oz';                          s = '16 oz';    u = ''; want = '16 oz' }
    # a wrapped record leaves junk with no measure in the card-size field; the NAME must still be read
    @{ n = 'l oven fresh keto friendly white bread 14 oz';     s = '449 L';    u = ''; want = '14 oz' }
    @{ n = 'l oven fresh artisanal style bread 20 oz';         s = '329 L';    u = ''; want = '20 oz' }
    @{ n = 'l oven fresh original english muffins 12 oz';      s = '159 L';    u = ''; want = '12 oz' }
    # ...but a card size that DOES state a measure still wins over the name
    @{ n = 'brioche buns 10 58 oz';                           s = '6 ct';     u = ''; want = '6 ct' }
    # a slug-collapsed decimal with nothing to corroborate it must be REFUSED, not read as its last number
    @{ n = 'l oven fresh garlic knots 10 4 oz';                s = '299 L';    u = ''; want = '' }
    @{ n = 'raspberry filled croissant 9 59 oz';               s = '';         u = ''; want = '' }
    @{ n = 'ground beef patties 2 5 lb';                       s = '';         u = ''; want = '' }
    # a genuine pack form keeps working - the pack word separates the two numbers
    @{ n = 'purified water 24 pk 16.9 fl oz';                  s = '';         u = ''; want = '24 pk 16.9 fl oz' }
    # FOUNDING BUG (2026-08-15): a liquid carded in bare "oz" took the Ice Cream crown measured as a WEIGHT on a
    # volume-priced row. The name states the volume and the arithmetic agrees, so relabel the KIND - never the number.
    @{ n = 'sundae shoppe vanilla flavored light ice cream, 1 gal'; s = '128 oz'; u = ''; want = '128 fl oz' }
    @{ n = 'friendly farms half gal chocolate milk';                s = '64 oz';  u = ''; want = '64 fl oz' }
    @{ n = 'store brand orange juice 2 qt';                        s = '64 oz';  u = ''; want = '64 fl oz' }
    # CLEAN TWINS - the equality is the whole proof, so these must come through untouched:
    # a real weight-oz item that merely ships in a pint-sized package keeps its WEIGHT
    @{ n = 'organic tomato package 1 pt';                          s = '10 oz';  u = ''; want = '10 oz' }
    # magnitude disagrees with the stated volume -> no proof, so no relabel
    @{ n = 'mystery juice 1 gal';                                  s = '32 oz';  u = ''; want = '32 oz' }
    # no volume in the name at all -> nothing to agree with
    @{ n = 'appleton farms sliced bacon';                          s = '128 oz'; u = ''; want = '128 oz' }
  )
  $fail = 0
  foreach ($c in $cases) {
    $got = Get-Size $c.n $c.s $c.u
    if ($got -eq $c.want) { Write-Output ("ok    '{0}' -> '{1}'" -f $c.n, $got) }
    else { Write-Output ("FAIL  '{0}' -> '{1}' (want '{2}')" -f $c.n, $got, $c.want); $fail++ }
  }
  # a weighted row must publish the PER-LB dollar, not the estimated package total
  $t = Invoke-Build @([pscustomobject]@{ name = 'fresh ground beef'; prices = '$11.97'; unit = '$3.99/lb'; size = ''; href = '' }) '2026-01-01'
  if ($t.rows.Count -eq 1 -and $t.rows[0].current_price -eq 3.99 -and $t.rows[0].size -eq 'lb') { Write-Output "ok    weighted row publishes the per-lb rate, not the pack estimate" }
  else { Write-Output "FAIL  weighted row basis"; $fail++ }

  # slug decimals: repair only where the card size proves the number, never on a guess
  $dcases = @(
    @{ n = 'happy harvest whole kernel corn 15 25 oz'; s = '15.25 oz'; want = 'happy harvest whole kernel corn 15.25 oz' }
    @{ n = 'original bratwurst 45 6 oz';               s = '45.6 oz';  want = 'original bratwurst 45.6 oz' }
    @{ n = 'some item 15 25 oz';                       s = '';         want = 'some item 15 25 oz' }        # no proof -> leave it
    @{ n = 'goldhen grade a large eggs 12 ct';         s = '12 ct';    want = 'goldhen grade a large eggs 12 ct' }
    @{ n = 'mystery 8 9 oz';                           s = '12.5 oz';  want = 'mystery 8 9 oz' }            # card proves other digits -> leave it
  )
  foreach ($d in $dcases) {
    $got = Repair-SlugDecimals $d.n $d.s
    if ($got -eq $d.want) { Write-Output ("ok    slug-decimal '{0}' -> '{1}'" -f $d.n, $got) }
    else { Write-Output ("FAIL  slug-decimal '{0}' -> '{1}' (want '{2}')" -f $d.n, $got, $d.want); $fail++ }
  }
  # WRAPPED-RECORD REJOIN. The founding bug: a 5-pipe head and a 1-pipe tail are BOTH under 6, so the first
  # version glued both onto the record above and destroyed it. H = complete record, W1/W2 = the two halves.
  $H1 = 'bread|bread|Loven Fresh White Bread 20 OZ|$1.45|$0.07 per oz|20 oz|https://x/a'
  $W1 = 'hamburger-buns|hamburger-buns|Specially Selected Sesame Seed Brioche Buns 10 58 OZ|$2.49|$0.24 per oz|6 ct'
  $W2 = 'https://x/b'
  $H2 = 'milk|milk|Friendly Farms Whole Milk 1 GAL|$2.19|$2.19 per gal|1 gal|https://x/c'
  $j = Join-WrappedRecords @($H1, $W1, $W2, $H2)
  if ($j.lines.Count -eq 3 -and $j.rejoined -eq 1 -and $j.lines[0] -eq $H1 -and $j.lines[2] -eq $H2 -and
      $j.lines[1] -eq ($W1 + ' ' + $W2)) {
    Write-Output 'ok    rejoin: a wrapped record is repaired and BOTH neighbouring records survive intact'
  } else {
    Write-Output ("FAIL  rejoin: got {0} line(s), rejoined={1}" -f $j.lines.Count, $j.rejoined); $fail++
    foreach ($l in $j.lines) { Write-Output ("        [{0}]" -f $l) }
  }
  # an incomplete fragment followed by a WHOLE record must never swallow it
  $j2 = Join-WrappedRecords @($W1, $H2)
  if ($j2.lines.Count -eq 2 -and $j2.lines[1] -eq $H2 -and $j2.rejoined -eq 0 -and $j2.orphans -eq 1) {
    Write-Output 'ok    rejoin: an orphan fragment does not eat the complete record that follows it'
  } else { Write-Output ("FAIL  rejoin orphan: {0} line(s), orphans={1}" -f $j2.lines.Count, $j2.orphans); $fail++ }
  # a clean file must pass through byte-identical
  $j3 = Join-WrappedRecords @($H1, $H2)
  if ($j3.lines.Count -eq 2 -and $j3.rejoined -eq 0 -and $j3.orphans -eq 0) { Write-Output 'ok    rejoin: a clean file is untouched' }
  else { Write-Output 'FAIL  rejoin clean-file no-op'; $fail++ }

  if ($fail) { Write-Output "$fail FAILED"; exit 1 } else { Write-Output "all self-tests pass"; exit 0 }
}

if (-not $In)   { throw 'build-aldi-regular: -In <capture.csv> is required' }
if (-not $Date) { $Date = (Get-Date -Format 'yyyy-MM-dd') }
$inPath = if ([IO.Path]::IsPathRooted($In)) { $In } else { Join-Path $root $In }
if (-not (Test-Path $inPath)) { throw "build-aldi-regular: no such capture $inPath" }

# REJOIN WRAPPED RECORDS BEFORE PARSING - see Join-WrappedRecords above for the algorithm and the trap.
$rawLines = Get-Content $inPath -Encoding UTF8
$jr = Join-WrappedRecords $rawLines
if ($jr.rejoined) { Write-Output ("build-aldi-regular: rejoined {0} line-wrapped record(s) before parsing" -f $jr.rejoined) }
if ($jr.orphans)  { Write-Output ("build-aldi-regular: {0} incomplete fragment(s) kept as-is (capture dropped a piece)" -f $jr.orphans) }
$tmp = Join-Path $env:TEMP ("aldi-capture-clean-" + $Date + ".csv")
Set-Content -Path $tmp -Value $jr.lines -Encoding UTF8

$raw = Import-CaptureCsv -Path $tmp -Delimiter '|'
if ($script:CaptureRepairCount -gt 0) { Write-Output ("  repaired $($script:CaptureRepairCount) mangled product name(s) on ingest (UTF-8 read as ANSI upstream)") }
$res = Invoke-Build $raw $Date
$rows = $res.rows
if ($rows.Count -lt 1) { throw 'build-aldi-regular: capture produced ZERO priced rows - do not write an empty file over a good one' }

$regDir = Join-Path $root 'out\regular'
if (-not (Test-Path $regDir)) { New-Item -ItemType Directory -Path $regDir -Force | Out-Null }
$outFile = Join-Path $regDir "aldi-regular-$Date.json"

$doc = [ordered]@{
  store         = 'Aldi'
  week_of       = $Date
  price_type    = 'everyday'
  price_mode    = 'in-store'
  mode_verified = $Date
  source        = 'aldi.us storefront search (ALDI - OLA 42 - Omaha, In-Store fulfillment)'
  pull_terms    = @($raw | ForEach-Object { $_.term } | Sort-Object -Unique).Count
  deal_count    = $rows.Count
  deals         = $rows
}
($doc | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8

$rejFile = Join-Path $root "out\aldi-rejects-$Date.json"
($res.rejects | ConvertTo-Json -Depth 4) | Set-Content $rejFile -Encoding UTF8

$why = $res.rejects | Group-Object why | Sort-Object Count -Descending
Write-Output ("build-aldi-regular: {0} raw -> {1} priced rows over {2} search terms -> aldi-regular-$Date.json" -f $raw.Count, $rows.Count, $doc.pull_terms)
Write-Output ("  rows carrying a product URL : {0}" -f (@($rows | Where-Object { $_.link_url }).Count))
if ($res.rejects.Count) {
  Write-Output ("  {0} rejected -> aldi-rejects-$Date.json" -f $res.rejects.Count)
  foreach ($g in $why) { Write-Output ("     {0}x {1}" -f $g.Count, $g.Name) }
}
