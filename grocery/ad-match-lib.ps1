<#
  ad-match-lib.ps1 - given a SALE cell with no window, find the ad row it came from and take its dates.

  BRAD'S RULE (2026-08-21): "if an item has a sale price, it MUST of been on some ad previously."
  Largely true, and where it is true the store has already told us when the sale ends - so the honest
  answer is to go and get that date, not to invent a TTL.

  *** THE BUG THIS LIBRARY EXISTS TO FIX ***
  Hy-Vee's butter cell published $2.48 as an undated sale. Brad pointed at the ad and asked why we
  missed it. We had not: out\ads-2026-08-21.json contained, in the 3 Day Sale flyer,

      "Hy-Vee butter, 16 oz., $2.48"      valid 2026-08-21 .. 2026-08-23

  The CAPTURE was fine; the MATCHER was wrong. An ad line is terse and a board item is the full
  product name:

      ad row     "Hy-Vee butter, 16 oz., $2.48"        distinctive tokens: {butter}
      board cell "Hy-Vee Sweet Cream Salted Butter Quarters"  {sweet, cream, salted, butter, quarters}

  "Hy-Vee", "16" and "oz" are stripped or stop-listed, so the ad row reduces to ONE distinctive word,
  and the old rule demanded TWO shared words. That is not a strict rule, it is an impossible one -
  no amount of correct capturing could ever have satisfied it.

  *** THE PRICE IS THE DISAMBIGUATOR, AND IT WAS SITTING THERE ***
  Both sides carry $2.48. A shared price plus ONE shared distinctive word is far stronger evidence
  than two shared words alone ("chicken breast" matches a dozen ad lines; "chicken breast at exactly
  $2.39/lb" matches one). So:

      match  =  (the ad line states this cell's price  AND  >=1 shared distinctive word)
             OR (>=2 shared distinctive words)                 <- the old rule, kept

  Kept as a UNION so this can only ever find more than before, never less. Measured on the live
  board: 155 -> 177 of 377 undated sale cells traced (Hy-Vee 53 -> 60, Fareway 102 -> 117).

  *** IT READS EVERY AD SOURCE ***
      out\ads-<date>.json               Hy-Vee (three concurrent flyers), Aldi, Family Fare
      out\fareway\fareway-deals-*.json  Fareway weekly + monthly, vision-read from the JPGs
      out\bakers\bakers-deals-*.json    Baker's flyer, vision-read
  Comparing Fareway against ads-*.json alone compares it against ZERO rows and declares every Fareway
  sale untraceable. That mistake was made once already on 2026-08-21; the loader below is why it
  cannot be made again.

  A WINDOW IS ONLY TAKEN FROM AN AD THAT IS LIVE. An expired flyer's dates would retire the cell
  immediately, and a future flyer's would keep it alive past its real end.
#>

$script:AM_STOP = @('fresh','hyvee','fareway','with','from','each','pack','size','count','select',
                    'varieties','assorted','your','choice','when','more','less','spend','save',
                    'kroger','simply','great','value','only','sale','price','pkg','lb.','ea.')

function Get-AmTokens([string]$s) {
  $t = (($s -replace '[^A-Za-z0-9 ]', ' ').ToLower()) -split '\s+'
  return @($t | Where-Object { $_.Length -gt 3 -and $script:AM_STOP -notcontains $_ })
}

function Get-AmPrices([string]$s) {
  $out = New-Object System.Collections.Generic.List[double]
  foreach ($m in [regex]::Matches([string]$s, '\$\s?(\d+(?:\.\d{1,2})?)')) {
    $v = 0.0; if ([double]::TryParse($m.Groups[1].Value, [ref]$v)) { [void]$out.Add($v) }
  }
  return $out
}

function Import-AdRows {
  <#
    .SYNOPSIS Every ad row we hold today, indexed by store, with its window and price tokens.
    .PARAMETER BoardDate Rows whose window does not contain this date are skipped - see the header.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$OutDir,
    [Parameter(Mandatory)][string]$BoardDate,
    # TWO DIFFERENT QUESTIONS, TWO DIFFERENT POOLS (2026-08-21).
    #   "What window should this cell take?"  -> LIVE ads only. An expired flyer's dates would
    #      retire the cell on sight; a future flyer's would keep it alive past its real end.
    #   "Was this item ever advertised?"      -> ANY ad, including closed ones. Brad's rule says a
    #      sale price "MUST of been on some ad PREVIOUSLY", and a sale that started in last week's
    #      flyer and is still running is precisely the case worth recognising rather than filing as
    #      unexplained.
    # Conflating them cost 126 Fareway rows on the first run: the live-only pool held 66 ad rows
    # where the full history holds 267, and 54 extra cells were reported untraceable as a result.
    [switch]$IncludeExpired
  )

  $rows = New-Object System.Collections.Generic.List[object]
  $adsFile = Get-ChildItem (Join-Path $OutDir 'ads-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if ($adsFile) {
    foreach ($d in (Get-Content $adsFile.FullName -Raw | ConvertFrom-Json).deals) {
      [void]$rows.Add([pscustomobject]@{ store=[string]$d.store; text=([string]$d.item + ' ' + [string]$d.ad_price); from=[string]$d.ad_from; to=[string]$d.ad_to })
    }
  }
  foreach ($lane in @('fareway','bakers')) {
    $dir = Join-Path $OutDir $lane
    if (-not (Test-Path $dir)) { continue }
    foreach ($f in (Get-ChildItem (Join-Path $dir '*-deals-*.json') -EA SilentlyContinue)) {
      try { $doc = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
      foreach ($d in @($doc.deals)) {
        [void]$rows.Add([pscustomobject]@{
          store = [string]$(if ($d.store) { $d.store } else { $doc.store })
          text  = ([string]$d.item + ' ' + [string]$d.ad_price)
          from  = [string]$(if ($d.ad_from) { $d.ad_from } else { $doc.ad_from })
          to    = [string]$(if ($d.ad_to)   { $d.ad_to }   else { $doc.ad_to })
        })
      }
    }
  }

  $idx = @{}
  foreach ($r in $rows) {
    if (-not $r.store) { continue }
    # LIVE ADS ONLY. A closed flyer would retire the cell on sight; one that has not opened would
    # keep it alive past its real end. An undated ad row is still usable for MATCHING (it proves the
    # item was advertised) but contributes no window.
    if (-not $IncludeExpired) {
      if ($r.to -match '^\d{4}-\d{2}-\d{2}$' -and $r.to -lt $BoardDate) { continue }
      if ($r.from -match '^\d{4}-\d{2}-\d{2}$' -and $r.from -gt $BoardDate) { continue }
    }
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($w in (Get-AmTokens $r.text)) { [void]$set.Add($w) }
    if (-not $idx.ContainsKey($r.store)) { $idx[$r.store] = New-Object System.Collections.Generic.List[object] }
    [void]$idx[$r.store].Add([pscustomobject]@{ tokens=$set; prices=(Get-AmPrices $r.text); from=$r.from; to=$r.to; text=$r.text })
  }
  return $idx
}

function Find-AdForCell {
  <#
    .SYNOPSIS The live ad row this sale cell came from, or $null.
    .DESCRIPTION Price + shared words, OR two shared words - scored, best candidate wins. See the
                 header for why a two-word rule alone can never match a terse ad line.

    *** FIRST-MATCH-WINS WAS A BUG (2026-08-22) ***
    The loop used to RETURN the first ad row sharing one distinctive word and the cell's dollar
    figure. Ad flyers are full of same-price lines - a $1.99 page has cottage cheese, shredded
    cheese, yogurt and sour cream on it - so "Hy-Vee Shredded Cheddar Cheese 8 oz $1.99" took the
    window of whichever $1.99 cheese line came FIRST in the file, cottage cheese included, and the
    cell inherited another product's sale dates. Now every price-matching candidate is scored by
    token overlap (shared count, then Jaccard as the tie-break, brand and size words included) and
    the BEST one is taken.

    THE BAR RISES WITH THE EVIDENCE AVAILABLE. A cell with >= 3 distinctive tokens must share >= 2
    with the ad line - but only as many as the ad line HAS. The founding butter case is a 5-token
    cell against a 1-token ad ("Hy-Vee butter, 16 oz., $2.48" reduces to {butter}); demanding two
    shared words there is the impossible rule the header describes, so the requirement is
    min(2, ad-line tokens). Cottage cheese ({cottage, cheese}) has two tokens and shares one with
    the cheddar cell, so it fails the bar; the terse butter line has one and shares it, so it passes.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Index, [Parameter(Mandatory)][string]$Store,
        [string]$Item = '', [string]$PriceText = '')

  if (-not $Index.ContainsKey($Store)) { return $null }
  $ut = @(Get-AmTokens $Item | Select-Object -Unique)
  if (-not $ut.Count) { return $null }
  $cp = @(Get-AmPrices $PriceText)
  $cell = if ($cp.Count) { [double]$cp[0] } else { $null }

  $best = $null; $bestPrice = $false; $bestOverlap = 0; $bestJac = 0.0
  foreach ($a in $Index[$Store]) {
    $overlap = 0
    foreach ($w in $ut) { if ($a.tokens.Contains($w)) { $overlap++ } }
    if ($overlap -lt 1) { continue }
    $union = $ut.Count + $a.tokens.Count - $overlap
    $jac = if ($union -gt 0) { $overlap / [double]$union } else { 0.0 }
    $priceHit = $false
    if ($null -ne $cell) { foreach ($p in $a.prices) { if ([math]::Abs($p - $cell) -lt 0.005) { $priceHit = $true; break } } }
    if ($priceHit) {
      $need = if ($ut.Count -ge 3) { [math]::Min(2, $a.tokens.Count) } else { 1 }
      if ($overlap -lt $need) { continue }
    } elseif ($overlap -lt 2) { continue }           # the old two-word rule, kept, for rows with no price match
    # RANK: a price match beats any number of shared words (see the header); then more shared
    # words; then the tighter set (Jaccard), so a terse exact line beats a long line that merely
    # happens to contain the same words.
    $better = $false
    if ($null -eq $best) { $better = $true }
    elseif ($priceHit -ne $bestPrice) { $better = $priceHit }
    elseif ($overlap -ne $bestOverlap) { $better = ($overlap -gt $bestOverlap) }
    elseif ($jac -gt $bestJac + 1e-9) { $better = $true }
    if ($better) { $best = $a; $bestPrice = $priceHit; $bestOverlap = $overlap; $bestJac = $jac }
  }
  return $best
}
