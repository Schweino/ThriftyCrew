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
  $hay = if ($cardSize) { $cardSize } else { $name }

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
    }
    $u = [string]$r.href
    if ($u -match '^https?://') { $row['link_url'] = $u }
    [void]$rows.Add([pscustomobject]$row)
  }
  return @{ rows = $rows.ToArray(); rejects = $rejects.ToArray() }
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
  if ($fail) { Write-Output "$fail FAILED"; exit 1 } else { Write-Output "all self-tests pass"; exit 0 }
}

if (-not $In)   { throw 'build-aldi-regular: -In <capture.csv> is required' }
if (-not $Date) { $Date = (Get-Date -Format 'yyyy-MM-dd') }
$inPath = if ([IO.Path]::IsPathRooted($In)) { $In } else { Join-Path $root $In }
if (-not (Test-Path $inPath)) { throw "build-aldi-regular: no such capture $inPath" }

# REJOIN WRAPPED RECORDS BEFORE PARSING. The browser capture reads a card's innerText, and a size token can
# swallow the newline that follows it ("159" + \n + "L"), which writes a literal line break INSIDE a field and
# splits one record across two lines. Import-Csv then reads the tail as its own row, and the URL lands in the
# `term` column - 27 of 3041 rows on 2026-07-29, and every one of them silently lost its price. A record is
# 7 pipe-separated fields, so any line carrying fewer than 6 pipes is a continuation of the line above it.
$rawLines = Get-Content $inPath
$fixed = New-Object System.Collections.ArrayList
$rejoined = 0
foreach ($ln in $rawLines) {
  $pipes = ([regex]::Matches($ln, '\|')).Count
  if ($fixed.Count -gt 0 -and $pipes -lt 6) {
    $fixed[$fixed.Count - 1] = ([string]$fixed[$fixed.Count - 1]) + ' ' + $ln.Trim()
    $rejoined++
  } else {
    [void]$fixed.Add($ln)
  }
}
if ($rejoined) { Write-Output ("build-aldi-regular: rejoined {0} line-wrapped record(s) before parsing" -f $rejoined) }
$tmp = Join-Path $env:TEMP ("aldi-capture-clean-" + $Date + ".csv")
Set-Content -Path $tmp -Value $fixed.ToArray() -Encoding UTF8

$raw = Import-Csv $tmp -Delimiter '|'
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
