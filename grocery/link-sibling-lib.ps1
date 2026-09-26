<#
  link-sibling-lib.ps1 - does a See-item link name the product its board cell names, or a SIBLING of it?

  ONE COPY OF THE RULE, TWO READERS (2026-09-26, queue 2026-09-26-fab315). The rule was born inside
  audit-tile-integrity.ps1 (queue 2026-09-22-817976, tightened by 2026-09-26-9dc3f6) where it could only REPORT.
  derive-links-from-prices.ps1, the link resolver, now uses the SAME function to drop a link that a cell has
  outgrown: a link derived for one winning product stayed on the cell after the board's winner changed to a
  different product whose row carries no identity (a flyer sale row, an unproven price), because the resolver
  wrote a link only when it could derive a new one and never re-judged the one already there. 28 tiles on the
  2026-09-23 board, 27 of them real (Dr Pepper sale -> Jarritos, Orange gelatin -> Strawberry, StarKist -> Dolores).
  Two copies of a matcher drift apart; so there is one, here, and both scripts dot-source it.

  SCOPE OF A CLEAN REPORT: UNSOUND (a sibling whose name only OMITS words, or swaps a synonym, reads clean) and
  INCOMPLETE (about 1 flag in 8 on a held-out board was one product named two ways), which is why the resolver acts
  on it only when the cell's own price row cannot prove the link by URL.
#>
# THE SIBLING TEST (2026-09-25, queue 2026-09-22-817976). The accuracy grade compares a link's PRICE with the tile, never
# its NAME against the tile's own name, so a link to a sibling of the right brand (a grinder for ground pepper, meat sauce
# for tomato-basil, cherry yogurt for plain) read ACCURACY OK and surfaced only as a PRICE-DRIFT. The words returned
# here are the board name's content words the link's name does not carry (lower-cased, sizes, digits and filler dropped,
# a trailing plural folded). The first version named a tile a SIBLING on ANY missing word; over the comparison-2026-09-23
# board it flagged 68 to 76 of about 2,600 linked tiles and about half were one product named two ways (Aldi's
# 'Freshire Farms Asparagus' linked as 'Asparagus, Package'), so it could not block (queue 2026-09-26-9dc3f6).
#
# THE CONTRADICTION RULE (2026-09-26, queue 2026-09-26-9dc3f6). A shortened name OMITS words; a sibling REPLACES them. So
# a tile is a SIBLING only when the board name carries a word the link lacks AND the link carries a word the board lacks
# (Orange vs Strawberry gelatin, Dr Pepper vs Jarritos), or when the board states a formulation modifier the link does
# not (fat free, unsalted, no salt added). Before comparing: a word matches its typo, transposition or run-together form
# (Bookdale/Brookdale, Fluroide/Fluoride, Activenergy/Activ Energy, NatureSweet/Nature Sweet) and a shared 5-letter stem
# (Steamed/Steamable); the commodity's own id words say nothing about the variant (popsicle, powdered, soap) and are
# dropped; an ad range ('Gala or Granny Smith apples') fires only when EVERY alternative is contradicted.
# MEASURED, one row per pair, labels written before each run (scratch labels, 2026-09-26): on the 2026-09-23 board the
# old rule flagged 68, of which 30 were true siblings (44%); this rule flags 28, 27 true (96%), and on the frozen set
# fires 36 of 39 known siblings and 1 of 44 same-product pairs. Those pairs TUNED it. On a HELD-OUT set (the 2026-09-05
# board with that day's product-urls.json, 55 flagged pairs used for nothing else) it was right on 48 of 55 (87%),
# UNDER the 95% bar written before that run, so it STAYS REPORTED, NOT BLOCKING: as a hard fault it would drop about 1
# honest link in 8. What it still gets wrong: ad copy (coupon text, 'snack crackers' vs 'Original'), a descriptor
# swapped for a synonym ('Shaved' vs 'Thin'), and a one-sided variant it cannot see ('Chai Black Tea' vs 'Black Tea').
$script:TiSiblingFiller = @('and','with','the','of','for','in','a','an','or','oz','lb','lbs','ct','count','pack','pk','fl','gal','gallon','each','ea','bag','box','can','jar','bottle','size','ounce','ounces','pound','pounds','qt','pt','ml','kg','dozen','fz','floz',
  'package','pkg','bunch','fresh','natural','naturally','all','conventional','to','on','select','variety','pure','product','from','per','inch','style','type','bowl','cup','tub','tray','carton','pouch')
$script:TiSiblingModifiers = @('fat free','fat-free','nonfat','non-fat','low fat','lowfat','reduced fat','low sodium','reduced sodium','less sodium','no salt','unsalted','sugar free','sugar-free','no sugar','unsweetened','decaf','diet','zero sugar')
function Get-TiContentWords([string]$Name) {
  # ORDERED and de-duplicated: the ad-range rule reads the first word of the first alternative.
  $o = New-Object System.Collections.Generic.List[string]
  foreach ($t in ((([string]$Name).ToLower() -replace "[’']s\b", '' -replace '[^a-z0-9]', ' ') -split '\s+')) {
    if ($t.Length -lt 2 -or $t -match '\d' -or $script:TiSiblingFiller -contains $t) { continue }
    $f = $t
    if ($f.Length -gt 4 -and $f.EndsWith('ies')) { $f = $f.Substring(0, $f.Length - 3) + 'y' }
    elseif ($f.Length -gt 4 -and $f -match '(oes|ses|xes|ches|shes)$') { $f = $f.Substring(0, $f.Length - 2) }
    elseif ($f.Length -gt 3 -and $f.EndsWith('s') -and -not $f.EndsWith('ss')) { $f = $f.Substring(0, $f.Length - 1) }
    if ($script:TiSiblingFiller -contains $f) { continue }   # the folded form too: 'bowls' -> 'bowl', 'types' -> 'type'
    if (-not $o.Contains($f)) { $o.Add($f) }
  }
  return ,$o
}
function Test-TiOneEdit([string]$A, [string]$B) {
  # one substitution, insertion, deletion or adjacent transposition
  if ([math]::Abs($A.Length - $B.Length) -gt 1) { return $false }
  $i = 0; while ($i -lt $A.Length -and $i -lt $B.Length -and $A[$i] -eq $B[$i]) { $i++ }
  if ($A.Length -eq $B.Length) {
    if ($i -ge $A.Length) { return $true }
    if ($A.Substring($i + 1) -eq $B.Substring($i + 1)) { return $true }
    return ($i + 1 -lt $A.Length -and $A[$i] -eq $B[$i + 1] -and $A[$i + 1] -eq $B[$i] -and $A.Substring($i + 2) -eq $B.Substring($i + 2))
  }
  if ($A.Length -gt $B.Length) { return $A.Substring($i + 1) -eq $B.Substring($i) }
  return $B.Substring($i + 1) -eq $A.Substring($i)
}
function Test-TiWordIn([string]$W, $Other) {
  if ($Other.Contains($W)) { return $true }
  for ($k = 0; $k -lt $Other.Count; $k++) {
    $o = $Other[$k]
    if ($k + 1 -lt $Other.Count -and ($o + $Other[$k + 1]) -eq $W) { return $true }                       # Activ Energy
    $p = 0; while ($p -lt $W.Length -and $p -lt $o.Length -and $W[$p] -eq $o[$p]) { $p++ }
    if ($p -ge 5) { return $true }                                                                           # Steamed / Steamable
    if ($W.Length -ge 4 -and $o.Length -gt $W.Length -and ($o.StartsWith($W) -or $o.EndsWith($W))) { return $true }   # NatureSweet
    if ($W.Length -ge 5 -and $o.Length -ge 5 -and (Test-TiOneEdit $W $o)) { return $true }                   # Bookdale / Brookdale
  }
  return $false
}
function Get-TiContradiction([string]$BoardPart, $LinkWords, $IdWords) {
  $bw = Get-TiContentWords $BoardPart
  $miss = @($bw | Where-Object { -not (Test-TiWordIn $_ $LinkWords) -and -not $IdWords.Contains($_) })
  $extra = @($LinkWords | Where-Object { -not (Test-TiWordIn $_ $bw) -and -not $IdWords.Contains($_) })
  if ($miss.Count -and $extra.Count) { return ('lacks ' + ($miss -join ', ') + '; adds ' + ($extra -join ', ')) }
  return ''
}
# Returns '' when the link names the board's product, else the reason it names a SIBLING.
function Get-TiSiblingReason([string]$BoardName, [string]$LinkName, [string]$Id = '') {
  $idw = Get-TiContentWords ($Id -replace '-', ' ')
  $lw = Get-TiContentWords $LinkName
  $bl = ([string]$BoardName).ToLower(); $ll = ([string]$LinkName).ToLower()
  $mod = @($script:TiSiblingModifiers | Where-Object { $bl.Contains($_) -and -not $ll.Contains($_) })
  if ($mod.Count) { return ('board says ' + ($mod -join ', ') + '; link does not') }
  $alts = @([string]$BoardName -split '(?<=[A-Za-z]) or (?=[A-Za-z])')
  if ($alts.Count -gt 1) {
    # 'Farm Rich appetizers or meatballs': the brand leads the first alternative and governs the rest
    $a0 = Get-TiContentWords $alts[0]
    $lead = if ($a0.Count -and -not $idw.Contains($a0[0])) { $a0[0] } else { '' }
    for ($i = 1; $i -lt $alts.Count; $i++) { $alts[$i] = $lead + ' ' + $alts[$i] }
  }
  $why = @()
  foreach ($a in $alts) { $c = Get-TiContradiction $a $lw $idw; if (-not $c) { return '' }; $why += $c }
  return ($why -join ' | ')
}
