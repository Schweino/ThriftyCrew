<#
  hyvee-flyer-link-lib.ps1 - link a Hy-Vee flyer LINE to the one Aisles Online product it prices (SHADOW ONLY).

  Spec: design/PLAN-flyer-line-product-link-2026-09-26.md (ruled 2026-09-26, "Yes, build to that bar"). A Hy-Vee sale
  cell is a flyer line ('Hy-Vee aluminum foil, 50 or 75 sq. ft., $4.49'), not a product, so the verifier cannot re-read
  it (Test-TcFlyerLineNamesNoProduct in flag-verify-lib.ps1). This library decides, from store reads already taken,
  whether exactly one Hy-Vee product proves the line. It decides nothing else: it writes no board cell and no verdict.

  THE RULE (plan section 2). A candidate is LINKED only when all four hold:
    1. PRICE PROOF: the store's read says onSale AND its price equals the line's price TO THE CENT (per item, a
       multibuy compared as N for $X against the read's priceMultiple). Not close: equal.
    2. IDENTITY: every brand-and-family word of the line (of at least one of its 'or' alternatives) is in the
       candidate's name, and the commodity's own rule did not refuse the name (the caller supplies that verdict from
       Test-TcStoreNameIdentity; could-not-look is not a proof, so it fails too).
    3. SIZE: when the line states sizes, every size fact the candidate's name states in a unit family the line also
       states is one of the line's sizes or inside its range. The name is read first; Hy-Vee's size field is used only
       when the name states no size AND the field is one plain measure ('75 sq ft'), because the field alone is
       untrusted ('12 fl oz Cans' for a 12-pack, pull-regular-hyvee.ps1).
    4. UNIQUE AT THE CELL'S SIZE: of the candidates passing 1 to 3, exactly one product reads, through pu-lib's
       Get-LinkPerUnit at the line's price, the cell's own published per-unit (the cell prices ONE size). None, or two
       products at it, is unlinked.
  Anything else is UNLINKED with its reason, and an unlinked line keeps today's behaviour exactly (unverifiable,
  published). Abstaining is always safe; a wrong link withholds a real sale.

  VARIANT 2 (Brad, 2026-09-26, "Both loosenings"; every function defaults to variant 1, which is unchanged):
    2a. ABBREVIATIONS: before rule 2, a candidate name token found in $script:HfAbbrev ALSO contributes its expansion
        ('ckn' -> chicken). Rule 2 is otherwise unchanged: every brand-and-family word must still be in the name.
    4a. SETS: when two or more products pass rules 1 to 3 at the cell's size, the line is linked to the SET, but only
        when EVERY candidate that passes rules 2 and 3 at the cell's size also carries the line's exact in-window sale
        price (rule 1). One off-price, off-sale or unread member refuses the whole set. The set's lowest id (ordinal)
        is reported as `linked` and every member as `linked_set`. A single link is decided exactly as in variant 1.

  SCOPE OF A CLEAN REPORT: a line reported unlinked proves nothing about the line (UNSOUND for coverage by design); a
  link is COMPLETE only as far as the four rules above, which is what the measured bar is for.
  Dot-source after pu-lib.ps1 (Get-LinkPerUnit). NO param() block. Fixtures: grocery/test-hyvee-flyer-link.ps1.
#>

# Words that describe a pack, a unit or a promotion, never a product family. Brand words (hyvee included) are KEPT:
# 'Hy-Vee frosting' must never link to another brand's frosting at the same price.
$script:HfStop = @('oz','fl','lb','lbs','ct','pk','pkg','ml','liter','liters','litre','sq','ft','bag','bags','bottles',
  'bottle','each','ea','pack','value','count','gal','gallon','fresh','with','purchase','of','the','and','a','or','in',
  'no','ever','antibiotics','natural','from','pint','per','only')

function ConvertTo-TcFlyerTokens([string]$Text) {
  $s = ([string]$Text).ToLowerInvariant()
  $s = $s -replace '[®™©]', ''
  $s = $s -replace "['’]", ''
  $s = $s -replace '\bhy[\s-]?vee\b', 'hyvee'
  $s = $s -replace '\d+%', ' '
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($t in ($s -split '[^a-z0-9]+')) {
    if (-not $t -or $t -match '^\d') { continue }
    if ($script:HfStop -contains $t) { continue }
    $w = $t
    if ($w.Length -gt 3 -and $w.EndsWith('s') -and -not $w.EndsWith('ss')) { $w = $w.Substring(0, $w.Length - 1) }
    if (-not $out.Contains($w)) { $out.Add($w) }
  }
  # Returned unrolled (no leading comma): every caller assigns first, then wraps with @() (og-08).
  return $out.ToArray()
}

# VARIANT 2 ABBREVIATION MAP: Hy-Vee name token (after ConvertTo-TcFlyerTokens) -> the line word(s) it abbreviates.
# BUILT FROM EVIDENCE, NEVER GUESSED. Derived mechanically on 2026-09-26 from the 451 candidate reads (443 products) in
# grocery/hyvee/flyer-link-evidence-2026-09-26.jsonl: a pair was proposed when a name token was an ordered-letter
# subsequence of a line word the name lacked (same first letter, shorter), or the initials of consecutive missing line
# words. 47 pairs were proposed. Admitted by a criterion fixed BEFORE re-scoring: the short form is not itself an
# English word or another brand in the evidence (drops sol, scrub, season, peach/pch, which are stemming artefacts or
# words), and a 2-letter short form is an initialism or cited twice or more (drops mx, sc, sb); 'bl' keeps only its
# initialism. CAUTION: derived from the same evidence the bar is scored on, so it is fitted to that set, not held out.
# Each entry cites one product id and its read name; Test-TcFlyerAbbrevShape re-proves the shape in the fixtures.
$script:HfAbbrev = [ordered]@{
  'alum'     = @{ words = @('aluminum');              cite = '4211791 Hy-Vee Hvy Duty Alum Foil' }
  'bc'       = @{ words = @('betty', 'crocker');       cite = '3825660 BC Dark Choc Brownie Mix (8 cited)' }
  'bf'       = @{ words = @('beef');                  cite = '31909 Choice Rsrv Bf Bnls Chck Roast (3 cited)' }
  'bisc'     = @{ words = @('biscuit');               cite = '4217295 Hy-Vee Med Multi-Flvr Dog Bisc' }
  'bl'       = @{ words = @('black', 'label');         cite = '11366 Hormel BL Original Bacon (7 cited)' }
  'blk'      = @{ words = @('black');                 cite = '77228 Hormel Blk Label Orig Bacon' }
  'bnl'      = @{ words = @('boneless');              cite = '31796 Beef Chuck Bnls Arm Pot Roast (3 cited)' }
  'brst'     = @{ words = @('breast');                cite = '31768 Hy-Vee Chkn Brst Bnls Sknls VP' }
  'brwni'    = @{ words = @('brownie');               cite = '2133482 BC Delights Sltd Caramel Brwni' }
  'brwnie'   = @{ words = @('brownie');               cite = '39816 BC Delights Choc Chnk Brwnie (2 cited)' }
  'chck'     = @{ words = @('chuck');                 cite = '31909 Choice Rsrv Bf Bnls Chck Roast' }
  'chkn'     = @{ words = @('chicken');               cite = '31768 Hy-Vee Chkn Brst Bnls Sknls VP (4 cited)' }
  'chp'      = @{ words = @('chop');                  cite = '71609 Pork Loin America Cut Bnls Chp (2 cited)' }
  'chwy'     = @{ words = @('chewy');                 cite = '24331 Hy-Vee Chwy Granola Variety Pk (2 cited)' }
  'ckie'     = @{ words = @('cookie');                cite = '2998401 That''s Smart Fudge Creme Ckies' }
  'ckn'      = @{ words = @('chicken');               cite = '31783 Hy-Vee Ckn Thighs Fam Pk (14 cited)' }
  'csm'      = @{ words = @('chateau', 'ste', 'michelle'); cite = '90749 CSM Sauvignon Blanc (3 cited)' }
  'drumstck' = @{ words = @('drumstick');             cite = '297310 Grill Rdy Seasond Ckn Drumstck' }
  'dtr'      = @{ words = @('detergent');             cite = '2909703 That''s Smart Mtn Air Lndry Dtr' }
  'flvr'     = @{ words = @('flavor');                cite = '4217295 Hy-Vee Med Multi-Flvr Dog Bisc (2 cited)' }
  'grbr'     = @{ words = @('gerber');                cite = '39008 Grbr Pick Ups Spinach&Chs Rav (8 cited)' }
  'grmt'     = @{ words = @('gourmet');               cite = '58576 Hy-Vee 1938 Grmt Steak Sauce' }
  'ktchn'    = @{ words = @('kitchen');               cite = '4200652 Hy-Vee Tall Ktchn Drwstrng 13G (3 cited)' }
  'lil'      = @{ words = @('little');                cite = '3244782 Lil Debbie Strwbry Mini Mffns (2 cited)' }
  'lndry'    = @{ words = @('laundry');               cite = '2909703 That''s Smart Mtn Air Lndry Dtr' }
  'mffn'     = @{ words = @('muffin');                cite = '3244782 Lil Debbie Strwbry Mini Mffns' }
  'pnut'     = @{ words = @('peanut');                cite = '8039 Planters Redskin Spanish Pnuts' }
  'prk'      = @{ words = @('pork');                  cite = '71603 Fresh Prk Loin Top Loin Chp VP' }
  'prtn'     = @{ words = @('protein');               cite = '290048 NV Prtn Oats N Hny Granola (2 cited)' }
  'qkr'      = @{ words = @('quaker');                cite = '3336376 Qkr Protein Granola Choc Almnd (3 cited)' }
  'rsrv'     = @{ words = @('reserve');               cite = '31909 Choice Rsrv Bf Bnls Chck Roast (3 cited)' }
  'rst'      = @{ words = @('roast');                 cite = '66026 Beef Chuck Bnls Petite Pot Rst' }
  'sce'      = @{ words = @('sauce');                 cite = '3279352 Buffalo Wild Wings Hny BBQ Sce (9 cited)' }
  'tgh'      = @{ words = @('thigh');                 cite = '306862 Hy-Vee True Ckn Bnls/Sknls Tgh' }
  'thgh'     = @{ words = @('thigh');                 cite = '40802 Just Bare Bnls/Sknls Ckn Thghs' }
  'tilapi'   = @{ words = @('tilapia');               cite = '61898 Parm Tuscan Herb Encrst Tilapi' }
  'whl'      = @{ words = @('whole');                 cite = '10978 Bunny Luv Org Whl Carrots' }
  'wtr'      = @{ words = @('water');                 cite = '22954 Hy-Vee Ntrl Spring Wtr 24Pk (4 cited)' }
}

function Test-TcFlyerAbbrevShape([string]$Short, [string[]]$Words) {
  # True when $Short is the initials of $Words (two or more), or an ordered-letter subsequence of the ONE word, sharing
  # its first letter and shorter than it. The map's entries must all pass; a guessed expansion usually does not.
  if (@($Words).Count -ge 2) { return ((-join (@($Words) | ForEach-Object { $_[0] })) -eq $Short) }
  $w = [string]@($Words)[0]
  if ($Short.Length -lt 2 -or $Short.Length -ge $w.Length -or $Short[0] -ne $w[0]) { return $false }
  $i = 0; foreach ($ch in $w.ToCharArray()) { if ($i -lt $Short.Length -and $Short[$i] -eq $ch) { $i++ } }
  return ($i -eq $Short.Length)
}

function Expand-TcFlyerNameTokens([string[]]$Tokens) {
  # Variant 2: the name's tokens plus the expansion of every mapped abbreviation among them. Originals are kept.
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($t in @($Tokens)) {
    if (-not $out.Contains($t)) { $out.Add($t) }
    if ($script:HfAbbrev.Contains($t)) { foreach ($w in $script:HfAbbrev[$t].words) { if (-not $out.Contains($w)) { $out.Add($w) } } }
  }
  return $out.ToArray()
}

$script:HfUnitRx ='(fl\.?\s*oz|oz|lbs?|sq\.?\s*ft|ml|liters?|litres?|ltr|gal(?:lon)?|ct|count|pk|pack)\.?'

function ConvertTo-TcFlyerSizeFact([double]$Qty, [string]$UnitText) {
  # A stated size as (family, quantity in the family's base unit). $null for a unit this reader does not know.
  $u = ($UnitText.ToLowerInvariant() -replace '[\s\.]', '')
  switch -regex ($u) {
    '^floz$'               { return [pscustomobject]@{ family = 'volume'; qty = $Qty } }
    '^oz$'                 { return [pscustomobject]@{ family = 'weight'; qty = $Qty } }
    '^lbs?$'               { return [pscustomobject]@{ family = 'weight'; qty = $Qty * 16 } }
    '^ml$'                 { return [pscustomobject]@{ family = 'volume'; qty = $Qty / 29.5735 } }
    '^(liters?|litres?|ltr)$' { return [pscustomobject]@{ family = 'volume'; qty = $Qty * 33.814 } }
    '^gal(lon)?$'          { return [pscustomobject]@{ family = 'volume'; qty = $Qty * 128 } }
    '^sqft$'               { return [pscustomobject]@{ family = 'area'; qty = $Qty } }
    '^(ct|count|pk|pack)$' { return [pscustomobject]@{ family = 'count'; qty = $Qty } }
    default                { return $null }   # an unknown unit states no size fact: safe, it can only cost a link
  }
}

function Get-TcFlyerSizeSet([string]$Text) {
  # Every size the text states: single sizes, 'A or B unit' (two sizes) and 'A to B unit' / 'A-B unit' (a range).
  # Prices are removed first, so '$1.88 lb.' (a per-pound price) is never read as a one-pound size.
  $s = ([string]$Text).ToLowerInvariant()
  $s = $s -replace '\d+\s*/\s*\$\s*\d+(?:\.\d+)?', ' '
  $s = $s -replace '\$\s*\d+(?:\.\d+)?\s*(?:lb|ea|each)?\.?', ' '
  $n = '(\d+(?:\.\d+)?|\.\d+)'
  $sizes = New-Object System.Collections.Generic.List[object]
  $ranges = New-Object System.Collections.Generic.List[object]
  foreach ($m in [regex]::Matches($s, $n + '\s*(to|-|or)\s*' + $n + '\s*' + $script:HfUnitRx)) {
    $a = ConvertTo-TcFlyerSizeFact ([double]$m.Groups[1].Value) $m.Groups[4].Value
    $b = ConvertTo-TcFlyerSizeFact ([double]$m.Groups[3].Value) $m.Groups[4].Value
    if ($null -eq $a -or $null -eq $b) { continue }
    if ($m.Groups[2].Value -eq 'or') { $sizes.Add($a); $sizes.Add($b) }
    else { $ranges.Add([pscustomobject]@{ family = $a.family; lo = [math]::Min($a.qty, $b.qty); hi = [math]::Max($a.qty, $b.qty) }) }
    $s = $s.Replace($m.Value, ' ')
  }
  foreach ($m in [regex]::Matches($s, $n + '\s*' + $script:HfUnitRx + '(?![a-z])')) {
    $f = ConvertTo-TcFlyerSizeFact ([double]$m.Groups[1].Value) $m.Groups[2].Value
    if ($null -ne $f) { $sizes.Add($f) }
  }
  return [pscustomobject]@{ sizes = $sizes.ToArray(); ranges = $ranges.ToArray() }
}

function ConvertFrom-TcFlyerLine([string]$Text) {
  <# The line as { ok, why, alternatives (token arrays), qty_n, total_cents, per_lb, sizes, ranges }. #>
  $t = ([string]$Text).Trim()
  $r = [ordered]@{ ok = $false; why = ''; text = $t; alternatives = @(); qty_n = 0; total_cents = 0; per_lb = $false; sizes = @(); ranges = @() }
  $mm = [regex]::Matches($t, '(\d+)\s*/\s*\$\s*(\d+(?:\.\d{1,2})?)')
  if ($mm.Count -gt 0) {
    $m = $mm[$mm.Count - 1]
    $r.qty_n = [int]$m.Groups[1].Value
    $r.total_cents = [int][math]::Round([double]$m.Groups[2].Value * 100, [MidpointRounding]::AwayFromZero)
  } else {
    $pm = [regex]::Matches($t, '\$\s*(\d+(?:\.\d{1,2})?)(\s*lb\.?)?')
    if ($pm.Count -eq 0) { $r.why = 'the line carries no price this reader can parse'; return [pscustomobject]$r }
    $m = $pm[$pm.Count - 1]
    $r.qty_n = 1
    $r.total_cents = [int][math]::Round([double]$m.Groups[1].Value * 100, [MidpointRounding]::AwayFromZero)
    $r.per_lb = [bool]$m.Groups[2].Value
  }
  if ($r.qty_n -le 0 -or $r.total_cents -le 0) { $r.why = 'the line price is not a positive amount'; return [pscustomobject]$r }
  $family = ($t -split ',')[0]
  $alts = @($family -split '\s+or\s+')
  $bt = ConvertTo-TcFlyerTokens $alts[0]; $brand = @($bt) | Select-Object -First 1
  $list = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt $alts.Count; $i++) {
    $a = $alts[$i].Trim()
    $tok = ConvertTo-TcFlyerTokens $a; $tok = @($tok)
    # A lower-case alternative ('Sola bagels or bread') is the SAME brand's other family; a capitalised one
    # ('... or Mission BBQ sauce') names its own brand.
    if ($i -gt 0 -and $a -cmatch '^[a-z]' -and $brand -and -not ($tok -contains $brand)) { $tok = @($brand) + $tok }
    if ($tok.Count -gt 0) { $list.Add([string[]]$tok) }
  }
  if ($list.Count -eq 0) { $r.why = 'the line names no brand or family word'; return [pscustomobject]$r }
  $r.alternatives = $list.ToArray()
  $ss = Get-TcFlyerSizeSet $t
  $r.sizes = $ss.sizes; $r.ranges = $ss.ranges
  $r.ok = $true
  return [pscustomobject]$r
}

function Get-TcCandidateSizeFacts($Cand) {
  # The candidate's size facts from ITS NAME; the size field only when the name states none and the field is one
  # plain measure. Returns { facts, road }.
  $fromName = Get-TcFlyerSizeSet ([string]$Cand.name)
  if (@($fromName.sizes).Count -gt 0) { return [pscustomobject]@{ facts = @($fromName.sizes); road = 'name' } }
  $f = ([string]$Cand.size_field).Trim()
  if ($f -match ('^(\d+(?:\.\d+)?|\.\d+)\s*' + $script:HfUnitRx + '$')) {
    $x = ConvertTo-TcFlyerSizeFact ([double]$Matches[1]) $Matches[2]
    if ($null -ne $x) { return [pscustomobject]@{ facts = @($x); road = 'size-field' } }
  }
  return [pscustomobject]@{ facts = @(); road = 'none' }
}

function Test-TcFlyerSizeFactInLine($Fact, $Line) {
  foreach ($s in @($Line.sizes)) { if ($s.family -eq $Fact.family -and [math]::Abs($s.qty - $Fact.qty) -le (0.005 * [math]::Max($s.qty, 0.0001))) { return $true } }
  foreach ($g in @($Line.ranges)) { if ($g.family -eq $Fact.family -and $Fact.qty -ge ($g.lo * 0.995) -and $Fact.qty -le ($g.hi * 1.005)) { return $true } }
  return $false
}

function Test-TcFlyerCandidate {
  <# Rules 1 to 3 for one candidate. Returns { pass, reason }. $Cand: product_id, name, size_field, read_ok, on_sale,
     price, price_multiple, identity ('refused'|'admitted'|'silent'|'could-not-look'). -Variant 2 expands the name's
     abbreviations before rule 2. -SkipPrice judges rules 2 and 3 only (variant 2's set-membership question). #>
  param($Line, $Cand, [int]$Variant = 1, [switch]$SkipPrice)
  $no = { param([string]$w) [pscustomobject]@{ pass = $false; reason = $w } }
  if (-not $SkipPrice) {
    if (-not $Cand.read_ok) { return (& $no 'no in-window store read of this product') }
    if (-not [bool]$Cand.on_sale) { return (& $no 'the store read says onSale false') }
    $pc = [int][math]::Round([double]$Cand.price * 100, [MidpointRounding]::AwayFromZero)
    $pm = [int]$Cand.price_multiple; if ($pm -lt 1) { $pm = 1 }
    $priceOk = (($pm -eq $Line.qty_n) -and ($pc -eq $Line.total_cents)) -or (($pm -eq 1) -and (($pc * $Line.qty_n) -eq $Line.total_cents))
    if (-not $priceOk) { return (& $no ('price differs: the store reads ' + $pm + ' for $' + ('{0:0.00}' -f ($pc / 100.0)) + ', the line says ' + $Line.qty_n + ' for $' + ('{0:0.00}' -f ($Line.total_cents / 100.0)))) }
  }
  $nameTok = ConvertTo-TcFlyerTokens ([string]$Cand.name); $nameTok = @($nameTok)
  switch ($Variant) {
    1 { }
    2 { $nameTok = Expand-TcFlyerNameTokens $nameTok; $nameTok = @($nameTok) }
    default { throw ('Test-TcFlyerCandidate: unknown variant ' + $Variant) }
  }
  $famOk = $false; $missing = ''
  foreach ($alt in @($Line.alternatives)) {
    $miss = @(@($alt) | Where-Object { $nameTok -notcontains $_ })
    if ($miss.Count -eq 0) { $famOk = $true; break }
    if (-not $missing) { $missing = ($miss -join ',') }
  }
  if (-not $famOk) { return (& $no ('a family word is missing from the name: ' + $missing)) }
  $idv = [string]$Cand.identity
  switch ($idv) {
    'refused'        { return (& $no "the commodity's own rule refuses the name") }
    'could-not-look' { return (& $no 'the identity rule could not look (not a proof)') }
    'admitted'       { }
    'silent'         { }
    default          { throw ('Test-TcFlyerCandidate: unknown identity verdict: ' + $idv) }
  }
  if (@($Line.sizes).Count -gt 0 -or @($Line.ranges).Count -gt 0) {
    $cf = Get-TcCandidateSizeFacts $Cand
    $fams = @(@($Line.sizes) + @($Line.ranges) | ForEach-Object { $_.family } | Select-Object -Unique)
    $judged = @($cf.facts | Where-Object { $fams -contains $_.family })
    if ($judged.Count -eq 0) { return (& $no 'the line states a size and the product states none in the same unit') }
    foreach ($f in $judged) { if (-not (Test-TcFlyerSizeFactInLine $f $Line)) { return (& $no ('size outside the line: ' + ('{0:0.###}' -f $f.qty) + ' ' + $f.family)) } }
  }
  return [pscustomobject]@{ pass = $true; reason = 'price, identity and size proved' }
}

function Get-TcCandidateCellPerUnit($Line, $Cand, [string]$Unit) {
  # The candidate's per-unit at the LINE's per-item price, through the estate's own size reader.
  $each = ($Line.total_cents / 100.0) / [double]$Line.qty_n
  if ($Line.per_lb -and $Unit -eq 'lb') { return $each }
  # Get-LinkPerUnit reads the quantity from -size only, so the size TEXT goes there: the name when it states a size,
  # else the plain size field (the same road Get-TcCandidateSizeFacts took), else nothing and no per-unit.
  $cf = Get-TcCandidateSizeFacts $Cand
  switch ($cf.road) {
    'name'       { return (Get-LinkPerUnit -size ([string]$Cand.name) -unit $Unit -price $each -name ([string]$Cand.name)) }
    'size-field' { return (Get-LinkPerUnit -size ([string]$Cand.size_field) -unit $Unit -price $each -name ([string]$Cand.name)) }
    'none'       { return $null }
    default      { throw ('Get-TcCandidateCellPerUnit: unknown size road ' + $cf.road) }
  }
}

function Resolve-TcFlyerLink {
  <# Rule 4 over every candidate. Returns { linked (product id or ''), reason, rows (one per candidate) }. #>
  param($Line, $Candidates, [double]$CellPerUnit, [string]$Unit, [int]$Variant = 1)
  $rows = New-Object System.Collections.Generic.List[object]
  if ($Variant -ne 1 -and $Variant -ne 2) { throw ('Resolve-TcFlyerLink: unknown variant ' + $Variant) }
  if (-not $Line.ok) { return [pscustomobject]@{ linked = ''; linked_set = @(); reason = ('unparsed line: ' + $Line.why); rows = @() } }
  $atCell = @{}
  foreach ($c in @($Candidates)) {
    $v = Test-TcFlyerCandidate -Line $Line -Cand $c -Variant $Variant
    $pu = $null; $at = $false
    if ($v.pass) {
      $pu = Get-TcCandidateCellPerUnit $Line $c $Unit
      $at = ($null -ne $pu -and $CellPerUnit -gt 0 -and [math]::Abs([double]$pu - $CellPerUnit) -le (0.005 * $CellPerUnit))
      if ($at) { $atCell[[string]$c.product_id] = $true }
    }
    $rows.Add([pscustomobject]@{ product_id = [string]$c.product_id; passes_1_to_3 = $v.pass; reason = $v.reason; per_unit_at_line_price = $pu; at_cell_size = $at })
  }
  $ids = @($atCell.Keys)
  if ($ids.Count -eq 1) { return [pscustomobject]@{ linked = $ids[0]; linked_set = @($ids[0]); reason = 'exactly one product proves the line at the cell''s size'; rows = $rows.ToArray() } }
  if ($ids.Count -gt 1) {
    if ($Variant -eq 2) {
      # Rule 4a: every candidate that passes rules 2 and 3 at the cell's size must be in the price-proved set.
      $offPrice = New-Object System.Collections.Generic.List[string]
      foreach ($c in @($Candidates)) {
        if ($atCell.ContainsKey([string]$c.product_id)) { continue }
        $m = Test-TcFlyerCandidate -Line $Line -Cand $c -Variant $Variant -SkipPrice
        if (-not $m.pass) { continue }
        $mpu = Get-TcCandidateCellPerUnit $Line $c $Unit
        if ($null -ne $mpu -and $CellPerUnit -gt 0 -and [math]::Abs([double]$mpu - $CellPerUnit) -le (0.005 * $CellPerUnit)) { $offPrice.Add([string]$c.product_id) }
      }
      if ($offPrice.Count -gt 0) { return [pscustomobject]@{ linked = ''; linked_set = @(); reason = ('set refused: ' + $ids.Count + ' products prove the price but ' + $offPrice.Count + ' member(s) at the cell''s size do not (' + ($offPrice.ToArray() -join ',') + ')'); rows = $rows.ToArray() } }
      $sorted = [string[]]$ids; [Array]::Sort($sorted, [StringComparer]::Ordinal)
      return [pscustomobject]@{ linked = $sorted[0]; linked_set = $sorted; reason = ('set: ' + $sorted.Count + ' products at the cell''s size, every member at the line''s exact sale price'); rows = $rows.ToArray() }
    }
    return [pscustomobject]@{ linked = ''; linked_set = @(); reason = ('ambiguous: ' + $ids.Count + ' products at the cell''s size'); rows = $rows.ToArray() }
  }
  $passing = @($rows | Where-Object { $_.passes_1_to_3 }).Count
  if ($passing -gt 0) { return [pscustomobject]@{ linked = ''; linked_set = @(); reason = ($passing.ToString() + ' candidate(s) pass rules 1 to 3, none at the cell''s size'); rows = $rows.ToArray() } }
  if (@($Candidates).Count -eq 0) { return [pscustomobject]@{ linked = ''; linked_set = @(); reason = 'no candidate'; rows = @() } }
  return [pscustomobject]@{ linked = ''; linked_set = @(); reason = 'no candidate passes rules 1 to 3'; rows = $rows.ToArray() }
}

function Get-TcFlyerLinkMode($Stores) {
  <# stores.json -> Hy-Vee -> flyer_link: shadow | live | off. Absent is OFF (nothing runs). 'live' is refused until
     Brad rules on the measured result (plan section 5 step 4): nothing here can act on a board. #>
  $hv = @($Stores.stores | Where-Object { [string]$_.name -eq 'Hy-Vee' }) | Select-Object -First 1
  if ($null -eq $hv -or -not $hv.PSObject.Properties['flyer_link']) { return 'off' }
  $v = ([string]$hv.flyer_link).Trim()
  switch ($v) {
    'off'    { return 'off' }
    'shadow' { return 'shadow' }
    'live'   { throw "stores.json Hy-Vee flyer_link is 'live', which is not built: a linked verdict goes live only after Brad rules on the measured result" }
    default  { throw ("stores.json Hy-Vee flyer_link: unknown value '" + $v + "' (shadow | live | off)") }
  }
}
