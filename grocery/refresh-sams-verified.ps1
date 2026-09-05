<#
  refresh-sams-verified.ps1 - re-price the hand-verified Sam's rows from a fresh capture WITHOUT re-deriving
  their size.

  THE GAP THIS CLOSES (C1's last open item, 2026-08-02). build-sams-deals.ps1 derives pack size from Sam's
  own arithmetic, qty = linePrice / unitPrice, and refuses to publish any row it cannot check that way. That
  refusal is correct and it stays - it is the whole reason the 2026-07-15 capture was quarantined. But it
  leaves two classes permanently unbuildable, and today's capture proves neither is going to fix itself:
    * "sft"  - Sam's prices foil / plastic wrap / parchment / toilet paper per SQUARE FOOT while the board
               tracks them per EACH or per ROLL. There is no honest conversion from square feet to rolls, so
               45 of today's 74 rejects are this one word.
    * no unitPrice at all - cauliflower, pineapple, rotisserie chicken, charcoal, corn dogs, egg pasta.
               20 more rejects. Nothing to divide by, so no size can be derived.
  Result: 11 live board cells still priced from a capture made 2026-07-26, and guard 9 warning about it on
  every single run because the file its rows live in can never get younger.

  THE INSIGHT THAT MAKES THIS SAFE. We do not need to derive the size - we already HAVE it, hand-verified,
  in out\regular\sams-regular-<date>.json. The only stale thing is the PRICE, and the capture has that.
  So this takes the store's current linePrice and keeps the size that was already checked, which is the same
  move pull-regular-hyvee makes when it cannot re-derive a row: keep what was verified, refresh what wasn't.

  WHAT IT REFUSES, and why each refusal exists rather than being a guess:
   1. NO MATCH IN A CAPTURE DATED TODAY. Captures from other days are ignored entirely - re-stamping a row
      as fresh on the strength of a three-day-old file is exactly the as_of laundering fixed in Fareway on
      2026-08-02, and it would be worse here because guard 9 reads this file.
   2. MORE THAN ONE PRICE among the name matches. "Member's Mark Crushed Red Pepper" matches a $5.98 jar and
      a $25.98 one; nothing in the name says which the stored 13.5 oz size belongs to. Two candidate prices
      for one size is not a refresh, it is a coin flip.
   3. A BARE PER-UNIT SIZE ("lb", "oz", "each" as a rate). linePrice is what the PACK costs. Writing it
      against size="lb" republishes it as the price of one pound - the honeydew bug that took a crown with
      the store's own arithmetic on 2026-07-29. Whole Pork Tenderloins is stored that way and is refused.
   4. A SIZE THE NAME NO LONGER CORROBORATES. This is the one that earns its keep: the stored aluminum-foil
      row is "Reynolds Wrap Heavy Duty 18 Inch Aluminum Foil, 2 pk" at 2 ct, and today Sam's carries the
      same line in 120 sq ft AND 150 sq ft packs at two different prices. A pack whose contents changed is a
      different product wearing the same name, and adopting its price under the old size mints a wrong
      per-unit. Every number in the stored size has to still be present in the product's own name.
   5. A SIZE THAT IS A PRICE. Two rows carry size="$0.20/oz" and size="$0.12/oz" - a per-unit price string
      in the size field. That is a corrupt row, not a small one, and it is named rather than carried.

  Rows that refuse are KEPT, unchanged, with their original as_of. A refusal costs freshness; deleting the
  row would cost the cell. The report names every one, so a stale Sam's cell is a stated fact and not a gap.

  Usage: .\refresh-sams-verified.ps1 -Date 2026-08-01 [-WhatIf]
         .\refresh-sams-verified.ps1 -SelfTest
#>
param(
  [string]$Date = "",
  [string]$Root = "",
  [switch]$WhatIf,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($Root) { $Root } elseif ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }

# count-ish units that mean the same thing on a Sam's pack. "2 pk" in our size and "2 rolls" in Sam's name
# are one fact spelled two ways, and refusing over the spelling would reject every paper good we track.
$COUNTU = @('ct','count','pk','pack','packs','rolls','roll','ea','each','bags','bag','boxes','box','jars','jar','cans','can','bottles','bottle')
function Get-SamsKey([string]$s) {
  $k = ([string]$s).ToLower()
  $k = ($k -replace '[^a-z0-9]', ' ')
  return ($k -replace '\s+', ' ').Trim()
}
# Every (number, unit) pair a size string states. Deliberately strict about what counts as a unit: an
# unrecognised token yields nothing, and a size that yields NOTHING is refused by the caller rather than
# treated as trivially corroborated.
function Get-SizeFacts([string]$size) {
  $out = New-Object System.Collections.Generic.List[object]
  $s = ([string]$size).ToLower()
  # [\s-]* between the number and the unit, not \s*: Sam's writes "2-Pack, 20 lbs." with a HYPHEN, and
  # requiring whitespace read that pack as stating no count at all - which made the corroboration test
  # refuse Kingsford charcoal for "changing its pack" when nothing about it had changed. A false refusal is
  # quieter than a false match but it still costs a live cell its refresh.
  foreach ($m in [regex]::Matches($s, '(\d+(?:\.\d+)?)[\s\-]*(sq\s*\.?\s*ft|square\s+feet|fl\s*oz|floz|oz|ounces?|lbs?|pounds?|gal(?:lons?)?|qt|quarts?|pt|pints?|ct|count|pk|packs?|rolls?|ea|each)\b')) {
    $u = ($m.Groups[2].Value -replace '[\s.]', '')
    if ($u -match '^(sqft|squarefeet)$') { $u = 'sqft' }
    elseif ($u -match '^(floz)$') { $u = 'floz' }
    elseif ($u -match '^(oz|ounce|ounces)$') { $u = 'oz' }
    elseif ($u -match '^(lb|lbs|pound|pounds)$') { $u = 'lb' }
    elseif ($u -match '^gal') { $u = 'gal' }
    elseif ($u -match '^(qt|quart|quarts)$') { $u = 'qt' }
    elseif ($u -match '^(pt|pint|pints)$') { $u = 'pt' }
    else { $u = 'count' }   # ct / count / pk / pack(s) / roll(s) / ea / each all mean "how many"
    $out.Add(@{ n = [double]$m.Groups[1].Value; u = $u })
  }
  return $out
}
# The same reading applied to a PRODUCT NAME, so the two can be compared fact for fact.
function Get-NameFacts([string]$name) { return (Get-SizeFacts $name) }

function Test-SizeCorroborated([string]$size, [string]$name) {
  $sz = ([string]$size).Trim()
  if (-not $sz) { return @{ ok = $false; why = 'the stored row has no size at all' } }
  if ($sz -match '[$]|/\s*(oz|lb|ea|ct|floz)') { return @{ ok = $false; why = ("size '" + $sz + "' is a PRICE, not a size - a corrupt row, refused rather than carried forward") } }
  $facts = Get-SizeFacts $sz
  $nameFacts = Get-NameFacts $name
  if ($facts.Count -eq 0) {
    # A bare token. "each" is a real quantity (one item, and linePrice is what one costs) as long as the
    # product is not secretly a multipack. "lb"/"oz"/"fl oz" are RATES, and a pack price is not a rate.
    if ($sz -match '^(?i)(each|ea|1\s*ct)$') {
      foreach ($f in $nameFacts) { if ($f.u -eq 'count' -and $f.n -gt 1) { return @{ ok = $false; why = ("stored size 'each' but the product name states " + $f.n + " per pack") } } }
      return @{ ok = $true; why = 'sold as one item and the name states no multipack' }
    }
    return @{ ok = $false; why = ("stored size '" + $sz + "' is a per-unit BASIS, and linePrice is what the PACK costs - publishing it against this size would price a whole pack as one " + $sz) }
  }
  foreach ($f in $facts) {
    $hit = $false
    foreach ($nf in $nameFacts) { if (($nf.u -eq $f.u) -and ([math]::Abs($nf.n - $f.n) -lt 0.005)) { $hit = $true; break } }
    if (-not $hit) { return @{ ok = $false; why = ("the product name no longer states '" + ('{0:0.####}' -f $f.n) + " " + $f.u + "' from the stored size '" + $sz + "' - the pack may have changed under the same name") } }
  }
  return @{ ok = $true; why = 'every number in the stored size is still stated by the product name' }
}

function Read-SamsCaptures([string]$base, [string]$dateS) {
  $rows = New-Object System.Collections.Generic.List[object]
  $files = New-Object System.Collections.Generic.List[object]
  foreach ($glob in @('out\sams\*.csv', 'out\captures\sams-*.csv')) {
    foreach ($f in @(Get-ChildItem (Join-Path $base $glob) -ErrorAction SilentlyContinue)) {
      if ($f.BaseName -match ([regex]::Escape($dateS) + '$')) { $files.Add($f) }
    }
  }
  foreach ($f in $files) {
    foreach ($line in (Get-Content $f.FullName -Encoding UTF8 | Select-Object -Skip 1)) {
      $p = $line -split '\|'
      if ($p.Count -lt 3) { continue }
      $nm = [string]$p[1]
      $lpS = ([string]$p[2]).Trim()
      $lp = 0.0; [void][double]::TryParse(($lpS -replace '[^0-9.]', ''), [ref]$lp)
      if (-not $nm -or $lp -le 0) { continue }
      $rows.Add([pscustomobject]@{ name = $nm; key = (Get-SamsKey $nm); price = $lp; src = $f.Name })
    }
  }
  return @{ rows = $rows; files = @($files | ForEach-Object { $_.Name }) }
}

function Invoke-SamsRefresh([string]$base, [string]$dateS, [bool]$whatIf) {
  $regDir = Join-Path $base 'out\regular'
  $prev = @(Get-ChildItem (Join-Path $regDir 'sams-regular-*.json') -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '^sams-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1)
  if ($prev.Count -eq 0) { return @{ text = 'sams-refresh: no out\regular\sams-regular-<date>.json to refresh'; refreshed = 0; refused = 0 } }
  $doc = Read-JsonFile $prev[0].FullName
  $cap = Read-SamsCaptures $base $dateS
  if ($cap.rows.Count -eq 0) {
    return @{ text = ("sams-refresh: NO capture file dated " + $dateS + " under out\sams or out\captures - nothing was re-verified, and this is a blind run rather than a clean one"); refreshed = 0; refused = 0; blind = $true }
  }
  # Index by key once. Multiple capture rows for one product are normal (the same item comes back under
  # several search terms); what matters is whether they agree on the price.
  $byKey = @{}
  foreach ($r in $cap.rows) {
    if (-not $byKey.ContainsKey($r.key)) { $byKey[$r.key] = New-Object System.Collections.Generic.List[object] }
    $byKey[$r.key].Add($r)
  }
  $keys = @($byKey.Keys)

  $refreshed = New-Object System.Collections.Generic.List[string]
  $refused = New-Object System.Collections.Generic.List[string]
  foreach ($d in @($doc.deals)) {
    $vk = Get-SamsKey ([string]$d.item)
    if (-not $vk) { continue }
    $matches = New-Object System.Collections.Generic.List[object]
    if ($byKey.ContainsKey($vk)) { foreach ($m in $byKey[$vk]) { $matches.Add($m) } }
    else {
      # The stored names were written without Sam's trailing size clause ("Cauliflower" vs "Cauliflower,
      # 1 ct."), so a PREFIX on a word boundary is the relation that actually holds. Anchored at the start
      # and requiring the boundary, so "corn starch" can never match "corn starch pudding".
      foreach ($k in $keys) { if ($k.StartsWith($vk + ' ')) { foreach ($m in $byKey[$k]) { $matches.Add($m) } } }
    }
    if ($matches.Count -eq 0) { $refused.Add(("{0} - no product with this name in the {1} capture" -f $d.item, $dateS)); continue }
    $prices = @($matches | ForEach-Object { $_.price } | Sort-Object -Unique)
    if ($prices.Count -gt 1) {
      $refused.Add(("{0} - {1} different prices match this name ({2}) and nothing says which one the stored size belongs to" -f $d.item, $prices.Count, (($prices | ForEach-Object { '$' + $_ }) -join ' / ')))
      continue
    }
    $best = $matches[0]
    $chk = Test-SizeCorroborated ([string]$d.size) ([string]$best.name)
    if (-not $chk.ok) { $refused.Add(("{0} - " + $chk.why) -f $d.item); continue }
    $oldAd = [string]$d.ad_price
    $newAd = '$' + ('{0:0.##}' -f $best.price)
    $d.ad_price = $newAd
    if ($d.PSObject.Properties['regular']) { $d.regular = $best.price }
    if ($d.PSObject.Properties['current_price']) { $d.current_price = $best.price } else { $d | Add-Member -NotePropertyName current_price -NotePropertyValue $best.price -Force }
    if ($d.PSObject.Properties['as_of']) { $d.as_of = $dateS } else { $d | Add-Member -NotePropertyName as_of -NotePropertyValue $dateS -Force }
    $d | Add-Member -NotePropertyName reverified -NotePropertyValue ("linePrice from " + $best.src + "; size kept from the verified row (" + $chk.why + ")") -Force
    $moved = if ($oldAd -ne $newAd) { " (was $oldAd)" } else { '' }
    $refreshed.Add(("{0} -> {1}{2}  [{3}]" -f $d.item, $newAd, $moved, [string]$d.size))
  }

  $note = ("sams-refresh {0}: re-priced {1} verified row(s) from {2}, refused {3} (kept, unchanged, with their original date)" -f $dateS, $refreshed.Count, ($cap.files -join ' + '), $refused.Count)
  if (-not $whatIf) {
    if ($doc.PSObject.Properties['refresh_note']) { $doc.refresh_note = $note } else { $doc | Add-Member -NotePropertyName refresh_note -NotePropertyValue $note -Force }
    $outPath = Join-Path $regDir ('sams-regular-' + $dateS + '.json')
    $doc | ConvertTo-Json -Depth 6 | Set-Content $outPath -Encoding UTF8
    $note += (" -> " + (Split-Path $outPath -Leaf))
  } else { $note += '  [WhatIf - nothing written]' }
  return @{ text = $note; refreshed = $refreshed; refused = $refused; count = $refreshed.Count; refusedCount = $refused.Count }
}

if ($SelfTest) {
  $fail = 0
  $T = Join-Path $env:TEMP ('samsref-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path (Join-Path $T 'out\regular') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $T 'out\sams') -Force | Out-Null
  try {
    function Chk([string]$label, [bool]$cond, [string]$got) {
      if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
    }
    # FROZEN FIXTURE - every row below is copied out of the real 2026-08-01 capture and the real verified
    # file. They encode the exact reasons build-sams-deals cannot publish these rows at all.
    @(
      'q|n|lp|up|id',
      # (a) sft: Sam's prices parchment per square foot, so the builder rejects it outright
      "parchment paper|Member's Mark Unbleached Parchment Paper, 205 sq. ft., 2 pk.|`$15.52|`$0.04/sft|1",
      # (b) no unitPrice at all, and the stored size is a bare 'each'
      'cauliflower|Cauliflower, 1 ct.|$3.99||2',
      # (c) MUST REFUSE: same line, two pack sizes, two prices - the live aluminum-foil case
      'aluminum foil|Reynolds Wrap Heavy Duty 18 Aluminum Foil, 120 sq. ft., 2 pk.|$21.78|$0.09/sft|3',
      'aluminum foil|Reynolds Wrap Heavy Duty 18 Aluminum Foil, 150 sq. ft., 2 pk.|$27.78|$0.09/sft|4',
      # (d) MUST REFUSE: the pack shrank under the same name
      'toilet paper|Store Brand Bath Tissue 30 rolls|$19.98||5',
      # (i) CLEAN TWIN for the hyphen: Sam's writes "2-Pack", and reading that as "no count stated" refused
      #     Kingsford charcoal on the live data for a pack change that never happened.
      'charcoal|Kingsford Original Charcoal Briquets, 2-Pack, 20 lbs.|$23.48||9',
      # (e) MUST REFUSE: a bare per-pound size against a pack price
      "pork|Member's Mark Whole Pork Tenderloins, Cryovac 4 lbs.|`$14.98||6",
      # (f) MUST REFUSE: a size field holding a price
      'corn starch|Clabber Girl Corn Starch, 2 pk, 16 oz.|$6.48||7',
      # (g) CLEAN TWIN: 'each' but the name says it is a 4-pack - must not adopt
      'pineapple|Pineapple, 4 ct.|$9.97||8'
    ) | Set-Content (Join-Path $T 'out\sams\capture-rescue-2026-08-01.csv') -Encoding UTF8
    @{ store = "Sam's Club"; price_type = 'everyday'; price_mode = 'in-store'; deals = @(
      @{ store = "Sam's Club"; item = "Member's Mark Unbleached Parchment Paper"; ad_price = '$15.52'; size = '2 pk 205 sq ft'; regular = 15.52; as_of = '2026-07-26' },
      @{ store = "Sam's Club"; item = 'Cauliflower'; ad_price = '$3.82'; size = 'each'; regular = 3.82; as_of = '2026-07-26' },
      # (c) stored WITHOUT the size clause, so it is a true prefix of BOTH capture rows and reaches the
      #     price-ambiguity branch. (h) below is the same product as it is ACTUALLY stored today ("18 Inch"
      #     where Sam's now writes 18"), which fails to match at all - a second, different refusal.
      @{ store = "Sam's Club"; item = 'Reynolds Wrap Heavy Duty 18 Aluminum Foil'; ad_price = '$19.98'; size = '2 ct'; regular = 19.98; as_of = '2026-07-26' },
      @{ store = "Sam's Club"; item = 'Reynolds Wrap Heavy Duty 18 Inch Aluminum Foil, 2 pk'; ad_price = '$19.98'; size = '2 ct'; regular = 19.98; as_of = '2026-07-26' },
      @{ store = "Sam's Club"; item = 'Store Brand Bath Tissue'; ad_price = '$24.76'; size = '45 ct'; regular = 24.76; as_of = '2026-07-26' },
      @{ store = "Sam's Club"; item = "Member's Mark Whole Pork Tenderloins, Cryovac"; ad_price = '$2.98'; size = 'lb'; regular = 2.98; as_of = '2026-07-26' },
      @{ store = "Sam's Club"; item = 'Clabber Girl Corn Starch, 2 pk'; ad_price = '$6.48'; size = '$0.20/oz'; regular = 6.48; as_of = '2026-07-26' },
      @{ store = "Sam's Club"; item = 'Pineapple'; ad_price = '$2.97'; size = 'each'; regular = 2.97; as_of = '2026-07-26' },
      @{ store = "Sam's Club"; item = 'Kingsford Original Charcoal Briquets'; ad_price = '$23.48'; size = '2 pk 20 lb'; regular = 23.48; as_of = '2026-07-26' }
    ) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T 'out\regular\sams-regular-2026-07-26.json') -Encoding UTF8

    $r = Invoke-SamsRefresh $T '2026-08-01' $false
    Write-Output ("      " + $r.text)
    $d = Read-JsonFile (Join-Path $T 'out\regular\sams-regular-2026-08-01.json')
    $by = @{}; foreach ($x in @($d.deals)) { $by[[string]$x.item] = $x }
    $ref = ($r.refused -join ' || ')
    Chk '(a) MUST FIRE  an "sft" row the builder can never publish IS re-priced' ($by["Member's Mark Unbleached Parchment Paper"].as_of -eq '2026-08-01' -and $by["Member's Mark Unbleached Parchment Paper"].size -eq '2 pk 205 sq ft') ("as_of=" + $by["Member's Mark Unbleached Parchment Paper"].as_of)
    Chk '(b) MUST FIRE  a no-unitPrice row takes the store price, keeps size "each"' ($by['Cauliflower'].ad_price -eq '$3.99' -and $by['Cauliflower'].size -eq 'each' -and $by['Cauliflower'].as_of -eq '2026-08-01') ("$($by['Cauliflower'].ad_price) / $($by['Cauliflower'].size)")
    Chk '(c) MUST REFUSE two pack sizes at two prices under one name' (($by['Reynolds Wrap Heavy Duty 18 Aluminum Foil'].ad_price -eq '$19.98') -and ($ref -match 'different prices match this name')) $ref
    Chk '(h) MUST REFUSE a stored name no capture row matches (18 Inch vs 18")' (($by['Reynolds Wrap Heavy Duty 18 Inch Aluminum Foil, 2 pk'].ad_price -eq '$19.98') -and ($ref -match 'no product with this name')) $ref
    Chk '(d) MUST REFUSE the pack shrank 45 -> 30 under the same name' (($by['Store Brand Bath Tissue'].ad_price -eq '$24.76') -and ($ref -match 'no longer states')) $ref
    Chk '(e) MUST REFUSE a bare per-lb size against a PACK price' (($by["Member's Mark Whole Pork Tenderloins, Cryovac"].ad_price -eq '$2.98') -and ($ref -match 'per-unit BASIS')) $ref
    Chk '(f) MUST REFUSE a size field that holds a price' (($by['Clabber Girl Corn Starch, 2 pk'].ad_price -eq '$6.48') -and ($ref -match 'is a PRICE, not a size')) $ref
    Chk '(g) MUST REFUSE "each" when the name says 4 ct' (($by['Pineapple'].ad_price -eq '$2.97') -and ($ref -match 'name states 4 per pack')) $ref
    Chk 'refused rows keep their ORIGINAL date, never today''s' ($by['Pineapple'].as_of -eq '2026-07-26' -and $by["Member's Mark Whole Pork Tenderloins, Cryovac"].as_of -eq '2026-07-26') ("pineapple as_of=" + $by['Pineapple'].as_of)
    Chk 'a re-priced row records WHERE its price came from' ($by['Cauliflower'].reverified -match 'capture-rescue-2026-08-01') ("" + $by['Cauliflower'].reverified)
    Chk '(i) CLEAN TWIN  "2-Pack" is a count - hyphen must not read as no-count' ($by['Kingsford Original Charcoal Briquets'].as_of -eq '2026-08-01' -and $by['Kingsford Original Charcoal Briquets'].ad_price -eq '$23.48') ("as_of=" + $by['Kingsford Original Charcoal Briquets'].as_of + " " + $ref)
    # BLIND: a capture from another day must not be used to claim freshness.
    $r2 = Invoke-SamsRefresh $T '2026-08-02' $true
    Chk 'a capture dated another day is NOT used - reported blind, not clean' ($r2.text -match 'blind run rather than a clean one') $r2.text
  } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

if (-not $Date) { throw 'refresh-sams-verified: -Date <yyyy-MM-dd> is required. It names the capture day, and a row may only be stamped with the date of the capture that actually re-verified it.' }
$res = Invoke-SamsRefresh $root $Date ([bool]$WhatIf)
Write-Output $res.text
if ($res.refreshed) { Write-Output '  RE-PRICED:'; foreach ($x in $res.refreshed) { Write-Output ('    ' + $x) } }
if ($res.refused)   { Write-Output '  REFUSED (kept as they were, with their original date):'; foreach ($x in $res.refused) { Write-Output ('    ' + $x) } }
if ($res.blind) { exit 3 }
exit 0
