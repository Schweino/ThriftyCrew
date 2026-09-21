<#
  flag-verify-lib.ps1 - A FLAGGED PRICE IS VERIFIED AGAINST THE STORE ITSELF, AND ONLY A DISAGREEMENT PAGES.

  Brad's design, approved in chat on 2026-09-21 ("Yes", after rejecting three narrower options with "I feel like none
  of these choices are right ones"). grocery/triage-plans/plan-2026-09-21-8.json. It supersedes open question
  Q-fccb69-unit-of-triage of plan-2026-09-21-6.json.

  WHY. sanity-check.ps1 is right to be sensitive, and prices move every day. Its only consumer used to be a person
  ("these still published; verify they are real"), so the channel fired on 22 of the 30 days ending 2026-09-21 however
  good each close was. The store is the source of truth for every price (.claude/rules/meal-prep.md, EVERY PRICE IS
  FETCHED) and the pipeline already re-reads every product it prices, so a flag is now a QUESTION put to the store:
    match           the store's own LATER read of the same product reproduces the published claim. The flag closes.
    wrong-price     it does not: no reading of the store's own figures gives our per-unit, or its shelf price is not
                    ours. The cell quarantines itself (audit-flag-verification.ps1) and ONE alert names it.
    wrong-product   a name the store gives the product is refused by the commodity's own rule. Same treatment.
    could-not-look  no later read yet (the lane has not re-read it, was throttled, or was walled), the store's figures
                    disagree with each other, or a sale claim was re-read outside its own ad window. PENDING: retried
                    on the next capture and never settled (memory a-could-not-look-must-not-settle-the-question: only
                    a real verdict closes the question).
  THE RE-READ IS THE LANE'S OWN NEXT READ of that product (a capture row whose as_of is strictly later than the claim's
  read and that is not a carried or not_reverified row), so every verification lookup comes out of the lane's existing
  budget and a throttled lookup can only leave a flag pending. A pending verification is an OWED re-read:
  Get-TcFlagVerifyOwed feeds the head of that store's next worklist, as a standing ruling's owed terms do.

  THREE TRAPS THIS FILE IS BUILT AROUND, each a frozen fixture in test-flag-verification.ps1:
    * THE STORE'S OWN UNIT PRICE CAN BE WRONG (Walmart's bouillon, Sam's oil jugs). Every reading of the store's figures
      is computed - shelf price over its size field, shelf price over the size its NAME states, its printed unit price -
      and none agreeing with ours is wrong-price, while some agreeing and some not is could-not-look, never match.
    * A SALE THAT HAS ENDED re-reads at the regular price. That can never CONFIRM a sale price, and cannot condemn one
      either (a real sale ends too), so a sale claim is compared on price only when the store's read falls inside the
      claim's own ad window. A package size never goes on sale, so size is still compared outside it.
    * A DISPLAY NAME CAN DROP THE WORD THAT MATTERS. Fareway's 'KIND Almond & Coconut' is, in the store's own product
      URL, kind-bars-almond-coconut. Identity is tested on every name the store gives the product.

  Dot-sourced by verify-price-flags.ps1, audit-flag-verification.ps1, capture-policy-lib.ps1 and
  test-flag-verification.ps1. NO param() block: a dot-sourced param() runs in the caller.
#>

$script:TcFlagQuietTypes    = @('outlier-verified', 'unit-changed', 'wow-explained')
$script:TcFlagVerifiedTypes = @('outlier', 'wow', 'native-mismatch')
$script:TcFlagLedgerName    = 'flag-verification.json'
# Closed entries stay readable this long so a cell that comes back is recognisable as the same cell. Not a bar on any
# price and not a tuning constant for a verdict; FIRST PLAUSIBLE NUMBER (the census window), nothing else tried.
$script:TcFlagClosedKeepDays = 30

function ConvertTo-TcFvDay($Text) {
  if ($null -eq $Text) { return $null }
  $s = ([string]$Text).Trim()
  if ($s.Length -gt 10) { $s = $s.Substring(0, 10) }
  $d = [datetime]::MinValue
  if ([datetime]::TryParseExact($s, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
  return $null
}

function ConvertTo-TcCents($Value) {
  # A shelf price as integer cents, or $null. Only a bare money figure qualifies ('$2.87', '2.87', 2.87): an ad SENTENCE
  # ('Gain Flings, EARN 10c OFF ... $12.94') or a multi-buy ('2 for $5') is not a shelf price and is never guessed at.
  if ($null -eq $Value) { return $null }
  if ($Value -is [double] -or $Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [single]) {
    $d = [double]$Value
    if ($d -le 0) { return $null }
    return [int64][math]::Round($d * 100, [MidpointRounding]::AwayFromZero)
  }
  $m = [regex]::Match(([string]$Value).Trim(), '^\$?\s*([0-9]+(?:\.[0-9]{1,2})?)$')
  if (-not $m.Success) { return $null }
  $v = [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
  if ($v -le 0) { return $null }
  return [int64][math]::Round($v * 100, [MidpointRounding]::AwayFromZero)
}

function ConvertTo-TcPuKey([double]$PerUnit) {
  # A per-unit price as an INTEGER count of ten-thousandths of a dollar: a bar is decided by integers, never by a double.
  return [int64][math]::Round($PerUnit * 10000, [MidpointRounding]::AwayFromZero)
}

# ---- READINGS OF THE STORE'S OWN FIGURES ---------------------------------------------------------------------------

function Get-TcPrintedUnitFactor([string]$CommodityUnit, [string]$PrintedUnit) {
  # How many commodity units one printed unit holds, or 0 when the two cannot be compared.
  $c = ([string]$CommodityUnit).Trim().ToLower(); $p = (([string]$PrintedUnit).Trim().ToLower() -replace '[\s.]', '')
  switch ($c) {
    'oz'     { if ($p -eq 'oz') { return 1.0 }; if ($p -eq 'lb') { return 16.0 }; return 0.0 }
    'lb'     { if ($p -eq 'lb') { return 1.0 }; if ($p -eq 'oz') { return 0.0625 }; return 0.0 }
    'floz'   { if ($p -eq 'floz' -or $p -eq 'oz') { return 1.0 }; if ($p -eq 'gal') { return 128.0 }; if ($p -eq 'qt') { return 32.0 }; return 0.0 }
    'each'   { if (@('ct', 'count', 'each', 'ea') -contains $p) { return 1.0 }; return 0.0 }
    'gallon' { if ($p -eq 'gal') { return 1.0 }; return 0.0 }
    default  { return 0.0 }   # a commodity unit this file does not know is NOT comparable, never assumed equal
  }
}

function Test-TcPrintedUnitAgrees([double]$OursPerUnit, [string]$CommodityUnit, [string]$Printed) {
  # The store's PRINTED unit price ('9.3 c/oz' with a cent sign, '$1.65/lb'). Returns 'agree', 'disagree' or '' (not
  # comparable). Compared in the PRINTED unit at the printed resolution: agree when ours is within HALF a unit of the
  # printed number's last digit. Both sides become integers of millionths of a dollar first, so a case AT the bar is
  # decided by integers: printed 9.3 cents/oz has resolution 0.1 cent = 1000 millionths, half is 500; ours 0.0935 is
  # 93500 against 93000 - 500, AT the bar, agree; 0.0936 is 600 past, disagree.
  $t = ([string]$Printed).Trim()
  if (-not $t) { return '' }
  $cent = [string][char]0x00A2
  $m = [regex]::Match($t, '^\s*(\$)?\s*([0-9]+)(?:\.([0-9]+))?\s*(' + $cent + '|c)?\s*/\s*(fl\.?\s*oz|oz|lb|ct|count|each|ea|gal|qt)\b', 'IgnoreCase')
  if (-not $m.Success) { return '' }
  $isCents = $m.Groups[4].Success -and -not $m.Groups[1].Success
  $digits = if ($m.Groups[3].Success) { $m.Groups[3].Value } else { '' }
  $num = [double]::Parse(($m.Groups[2].Value + $(if ($digits) { '.' + $digits } else { '' })), [Globalization.CultureInfo]::InvariantCulture)
  $f = Get-TcPrintedUnitFactor $CommodityUnit $m.Groups[5].Value
  if ($f -le 0) { return '' }
  $printedDollars = if ($isCents) { $num / 100.0 } else { $num }
  $resDollars = [math]::Pow(10, -1 * $digits.Length); if ($isCents) { $resDollars = $resDollars / 100.0 }
  $pU = [int64][math]::Round($printedDollars * 1000000, [MidpointRounding]::AwayFromZero)
  $oU = [int64][math]::Round($OursPerUnit * $f * 1000000, [MidpointRounding]::AwayFromZero)
  $tolU = [int64][math]::Round($resDollars * 1000000 / 2.0, [MidpointRounding]::AwayFromZero)
  if ([math]::Abs($oU - $pU) -le $tolU) { return 'agree' }
  return 'disagree'
}

function Get-TcNameSizeText([string]$Name) {
  # The size a product NAME states, rewritten in the form pu-lib's Get-LinkPerUnit reads, or ''. A separate READING of
  # the store's figures, never a fallback: 'Knorr Select ... Granulated Bouillon, 1.82 pounds' says 1.82 lb whatever
  # its size field and its printed unit price say. A pack count with a weight is written pack-first ('2 pk 24 oz').
  $n = ' ' + ([string]$Name).ToLower() + ' '
  $w = [regex]::Match($n, '([0-9]+(?:\.[0-9]+)?)\s*(fl\.?\s*oz\.?|fluid\s+ounces?|ounces?|oz\.?|lbs?\.?|pounds?|gallons?|gal\.?|quarts?|qt\.?)(?=[\s,;)/]|$)')
  $c = [regex]::Match($n, '([0-9]+)\s*-?\s*(pk\.?|pack|count|ct\.?)(?=[\s,;)/]|$)')
  $wt = ''
  if ($w.Success) {
    $u = $w.Groups[2].Value -replace '\.', ''
    # if/elseif, never switch -regex: a switch runs EVERY branch that matches, so 'fluid ounces' would come back as two units
    if ($u -match '^fl') { $u = 'fl oz' } elseif ($u -match '^(ounces?|oz)$') { $u = 'oz' } elseif ($u -match '^(lbs?|pounds?)$') { $u = 'lb' }
    elseif ($u -match '^(gallons?|gal)$') { $u = 'gal' } elseif ($u -match '^(quarts?|qt)$') { $u = 'qt' }
    else { $u = '' }   # a unit this reader does not know is no reading at all, never a guess
    if ($u) { $wt = $w.Groups[1].Value + ' ' + $u }
  }
  if ($wt -and $c.Success -and $c.Groups[2].Value -match '^(pk|pack)') { return ($c.Groups[1].Value + ' pk ' + $wt) }
  if ($wt) { return $wt }
  if ($c.Success) { return ($c.Groups[1].Value + ' ct') }
  return ''
}

function Get-TcStoreReadings($Answer, [string]$Unit, [int64]$ShelfCents) {
  # Every per-unit reading of the store's own figures, in the commodity's unit.
  $out = New-Object System.Collections.ArrayList
  $shelf = [double]$ShelfCents / 100.0
  $sz = ([string]$Answer.size).Trim()
  if ($sz) {
    $pf = Get-LinkPerUnit -size $sz -unit $Unit -price $shelf -name ([string]$Answer.item)
    if ($null -ne $pf) { [void]$out.Add([pscustomobject]@{ kind = 'size field'; text = $sz; per_unit = [double]$pf; key = (ConvertTo-TcPuKey ([double]$pf)) }) }
  }
  $ns = Get-TcNameSizeText ([string]$Answer.item)
  if ($ns) {
    $pn = Get-LinkPerUnit -size $ns -unit $Unit -price $shelf
    if ($null -ne $pn) { [void]$out.Add([pscustomobject]@{ kind = 'name size'; text = $ns; per_unit = [double]$pn; key = (ConvertTo-TcPuKey ([double]$pn)) }) }
  }
  return ,($out.ToArray())
}

# ---- IDENTITY ---------------------------------------------------------------------------------------------------------

function Get-TcUrlSlugName([string]$Url) {
  # The product's own name as the store spells it in its URL:
  #   Fareway/Aldi .../products/20002358-kind-bars-almond-coconut-6-ea    -> 'kind bars almond coconut 6 ea'
  #   Baker's      .../p/kroger-fresh-grape-tomatoes/0001111091686        -> 'kroger fresh grape tomatoes'
  #   Hy-Vee       .../aisles-online/p/37372/anaheim-peppers             -> 'anaheim peppers'
  #   Family Fare  .../<category>/<product_slug>/p/1764405684715885166   -> '<product slug>'
  $u = (([string]$Url).Trim() -split '[?#]')[0].TrimEnd('/')
  if (-not $u) { return '' }
  $seg = ''
  $m = [regex]::Match($u, '/products/([^/]+)$'); if ($m.Success) { $seg = $m.Groups[1].Value }
  if (-not $seg) { $m = [regex]::Match($u, '/p/[0-9]+/([^/]+)$'); if ($m.Success) { $seg = $m.Groups[1].Value } }
  if (-not $seg) { $m = [regex]::Match($u, '/p/([^/]*[a-zA-Z][^/]*)/[0-9]+$'); if ($m.Success) { $seg = $m.Groups[1].Value } }
  if (-not $seg) { $m = [regex]::Match($u, '/([^/]*[a-zA-Z][^/]*)/p/[0-9]+$'); if ($m.Success) { $seg = $m.Groups[1].Value } }
  if (-not $seg) { return '' }
  $seg = [uri]::UnescapeDataString($seg) -replace '^[0-9]+[-_]', ''
  return (($seg -replace '[-_]+', ' ').Trim())
}

function Get-TcStoreNames($Row) {
  # Every name the store gives this product: its display name, and the words of its own canonical product URL.
  $names = New-Object System.Collections.ArrayList
  $it = ([string]$Row.item).Trim()
  if ($it) { [void]$names.Add($it) }
  foreach ($k in @('link_url', 'canonical_url', 'url')) {
    if ($Row.PSObject.Properties[$k] -and [string]$Row.$k) {
      $sl = Get-TcUrlSlugName ([string]$Row.$k)
      if ($sl -and -not ($names -contains $sl)) { [void]$names.Add($sl) }
    }
  }
  return ,($names.ToArray())
}

function New-TcIdentityJudge($Commodities, [string[]]$GlobalExclude) {
  # One pair of matchers per commodity, built on first use through match-lib (the engine's own matcher, never a copy):
  # the commodity's OWN rule with its excludes and the global exclude list, and the same rule with no exclude at all.
  # A name the bare rule admits and the full rule refuses is a name the commodity's own rule has already ruled against.
  $byId = @{}
  foreach ($c in @($Commodities)) { if ($null -ne $c -and [string]$c.id) { $byId[[string]$c.id] = $c } }
  return [pscustomobject]@{ byId = $byId; cache = @{}; gex = @($GlobalExclude) }
}

function Test-TcStoreNameIdentity($Judge, [string]$Id, $Names) {
  # Returns { verdict: refused | admitted | silent | could-not-look ; name ; detail }.
  if (-not $Judge.byId.ContainsKey($Id)) { return [pscustomobject]@{ verdict = 'could-not-look'; name = ''; detail = ('commodity ' + $Id + ' is not in commodities.json') } }
  if (-not $Judge.cache.ContainsKey($Id)) {
    $c = $Judge.byId[$Id]
    $full = New-CommodityMatcher -Commodities @($c) -GlobalExclude ([string[]]$Judge.gex)
    $c2 = $c.PSObject.Copy(); $c2 | Add-Member -NotePropertyName exclude -NotePropertyValue @() -Force
    # New-CommodityMatcher refuses an empty global list, so the bare matcher gets one pattern that can never match.
    $bare = New-CommodityMatcher -Commodities @($c2) -GlobalExclude @('(?!)')
    $Judge.cache[$Id] = [pscustomobject]@{ full = $full; bare = $bare }
  }
  $m = $Judge.cache[$Id]
  $cnl = $false; $admitted = $false
  foreach ($n in @($Names)) {
    $nm = ([string]$n).Trim(); if (-not $nm) { continue }
    $b = Resolve-CommodityDetail -Matcher $m.bare -Name $nm
    $f = Resolve-CommodityDetail -Matcher $m.full -Name $nm
    if ($b.could_not_look -or $f.could_not_look) { $cnl = $true; continue }
    if ($null -ne $b.commodity -and $null -eq $f.commodity) {
      return [pscustomobject]@{ verdict = 'refused'; name = $nm; detail = ("admitted by " + $Id + "'s own pattern '" + [string]$b.include_hit + "' and refused by one of its excludes") }
    }
    if ($null -ne $f.commodity) { $admitted = $true }
  }
  if ($cnl) { return [pscustomobject]@{ verdict = 'could-not-look'; name = ''; detail = 'the matcher hit its time bound on a store name' } }
  if ($admitted) { return [pscustomobject]@{ verdict = 'admitted'; name = ''; detail = '' } }
  return [pscustomobject]@{ verdict = 'silent'; name = ''; detail = 'no store name carries this commodity''s own pattern' }
}

# ---- THE RE-READ ------------------------------------------------------------------------------------------------------

function Get-TcClaimReadDay($Claim) {
  # When the published claim was read. An everyday row carries as_of; an ad row carries none, and was read when its ad
  # window opened. No date at all means no later read can ever be recognised, which is a could-not-look, never a pass.
  $d = ConvertTo-TcFvDay $Claim.as_of
  if ($null -ne $d) { return $d }
  if ([string]$Claim.row_type -eq 'sale') { return (ConvertTo-TcFvDay $Claim.ad_from) }
  return $null
}

function Get-TcRowProductKey($Row) {
  foreach ($k in @('product_id', 'item_id')) {
    if ($Row.PSObject.Properties[$k] -and $null -ne $Row.$k -and ([string]$Row.$k).Trim()) { return ($k + ':' + ([string]$Row.$k).Trim()) }
  }
  return ''
}

function Find-TcStoreReread($Claim, $Rows) {
  # The store's answer: the NEWEST row of the same product whose as_of is STRICTLY LATER than the claim's read. Same
  # product = the product id the claim's own source row carries, else the same name. A carried row keeps its original
  # as_of, so it can never pass the date test; a Hy-Vee row marked not_reverified is a row nobody re-read today.
  $after = Get-TcClaimReadDay $Claim
  if ($null -eq $after) { return [pscustomobject]@{ row = $null; why = 'the published claim carries no read date (no as_of and no ad window start), so no later read can be recognised' } }
  $name = ([string]$Claim.item).Trim()
  $prodKey = ''
  foreach ($r in @($Rows)) {
    if ($null -eq $r) { continue }
    if ([string]::Equals(([string]$r.item).Trim(), $name, [StringComparison]::OrdinalIgnoreCase)) { $k = Get-TcRowProductKey $r; if ($k) { $prodKey = $k; break } }
  }
  $best = $null; $bestDay = $null
  foreach ($r in @($Rows)) {
    if ($null -eq $r) { continue }
    $same = $false
    if ($prodKey) { $same = [string]::Equals((Get-TcRowProductKey $r), $prodKey, [StringComparison]::Ordinal) }
    if (-not $same) { $same = [string]::Equals(([string]$r.item).Trim(), $name, [StringComparison]::OrdinalIgnoreCase) }
    if (-not $same) { continue }
    if ($r.PSObject.Properties['not_reverified'] -and [bool]$r.not_reverified) { continue }
    $d = ConvertTo-TcFvDay $r.as_of
    if ($null -eq $d -or $d -le $after) { continue }
    if ($null -eq $best -or $d -gt $bestDay) { $best = $r; $bestDay = $d }
  }
  if ($null -eq $best) { return [pscustomobject]@{ row = $null; why = ('no read of this product later than ' + $after.ToString('yyyy-MM-dd') + ' has landed yet') } }
  return [pscustomobject]@{ row = $best; why = '' }
}

# ---- THE VERDICT ------------------------------------------------------------------------------------------------------

function Resolve-TcRereadVerdict {
  <#
    The rule, in order. wrong-product beats wrong-price beats could-not-look beats match, and match needs EVERY test to
    pass on a store read that could see: a verdict that cannot be reached is could-not-look, which stays pending.
  #>
  param($Claim, $Answer, [string]$Unit, $Identity)
  $mk = { param([string]$v, [string]$why, $rd) [pscustomobject]@{ verdict = $v; reason = $why; readings = @($rd) } }
  if ($null -eq $Answer) { return (& $mk 'could-not-look' 'no later read of this product' @()) }
  if ($null -ne $Identity -and $Identity.verdict -eq 'refused') {
    return (& $mk 'wrong-product' ("the store's own name for it, '" + $Identity.name + "', is " + $Identity.detail) @())
  }
  $idBlind = ($null -ne $Identity -and $Identity.verdict -eq 'could-not-look')
  $oursPu = [double]$Claim.per_unit
  $oursKey = ConvertTo-TcPuKey $oursPu
  $shelf = ConvertTo-TcCents $Answer.current_price
  if ($null -eq $shelf) { $shelf = ConvertTo-TcCents $Answer.ad_price }
  if ($null -eq $shelf) { return (& $mk 'could-not-look' "the store's read carries no shelf price" @()) }
  $readings = Get-TcStoreReadings -Answer $Answer -Unit $Unit -ShelfCents $shelf
  $printed = @()
  foreach ($k in @('wm_unit_price', 'sams_unit_price', 'unit_price', 'store_unit_price')) {
    if ($Answer.PSObject.Properties[$k] -and [string]$Answer.$k) {
      $a = Test-TcPrintedUnitAgrees -OursPerUnit $oursPu -CommodityUnit $Unit -Printed ([string]$Answer.$k)
      if ($a) { $printed += [pscustomobject]@{ kind = 'printed unit price'; text = [string]$Answer.$k; agree = ($a -eq 'agree') } }
    }
  }
  $rdText = @(@($readings | ForEach-Object { $_.kind + ' ' + $_.text + ' -> ' + ('{0:0.0000}' -f $_.per_unit) }) + @($printed | ForEach-Object { $_.kind + ' ' + $_.text + ' -> ' + $(if ($_.agree) { 'agrees' } else { 'disagrees' }) }))
  $shelfText = ('$' + ('{0:0.00}' -f ([double]$shelf / 100)))

  $inWindow = $true
  if ([string]$Claim.row_type -eq 'sale') {
    $af = ConvertTo-TcFvDay $Claim.ad_from; $at = ConvertTo-TcFvDay $Claim.ad_to; $rd = ConvertTo-TcFvDay $Answer.as_of
    $inWindow = ($null -ne $af -and $null -ne $at -and $null -ne $rd -and $rd -ge $af -and $rd -le $at)
  }
  if (-not $inWindow) {
    # A SALE READ OUTSIDE ITS WINDOW. The store's price now is a different moment's price: it can never confirm the
    # sale (that is the trap) and it cannot condemn it (real sales end). A package size never goes on sale, so the
    # size is still compared: ours against every size the store states.
    $oq = $null
    $o1 = Get-LinkPerUnit -size ([string]$Claim.size) -unit $Unit -price 1.0 -name ([string]$Claim.item)
    if ($null -ne $o1 -and [double]$o1 -gt 0) { $oq = 1.0 / [double]$o1 }
    if ($null -eq $oq) {
      $oc = ConvertTo-TcCents $Claim.ad
      if ($null -ne $oc -and $oursPu -gt 0) { $oq = ([double]$oc / 100.0) / $oursPu }
    }
    $sq = @(@($readings) | ForEach-Object { ([double]$shelf / 100.0) / [double]$_.per_unit })
    if ($null -eq $oq -or $sq.Count -eq 0) {
      return (& $mk 'could-not-look' ("a sale read outside its own window (the store read it " + [string]$Answer.as_of + ", the sale ran " + [string]$Claim.ad_from + ".." + [string]$Claim.ad_to + ") cannot confirm or condemn a sale price, and there is no package size on both sides to compare") $rdText)
    }
    $oqk = [int64][math]::Round($oq * 1000, [MidpointRounding]::AwayFromZero)
    $hit = @($sq | Where-Object { [math]::Abs(([int64][math]::Round($_ * 1000, [MidpointRounding]::AwayFromZero)) - $oqk) -le 1 })
    if ($hit.Count -eq 0) {
      return (& $mk 'wrong-price' ("the package size differs: we publish a basis of " + ('{0:0.###}' -f $oq) + ' ' + $Unit + ", the store's own figures give " + ((@($sq | ForEach-Object { '{0:0.###}' -f $_ })) -join ' / ') + ' ' + $Unit + ' (a sale never changes a package size)') $rdText)
    }
    return (& $mk 'could-not-look' ("the sale window closed before the store re-read it (read " + [string]$Answer.as_of + ", sale " + [string]$Claim.ad_from + ".." + [string]$Claim.ad_to + "): a regular price can neither confirm nor condemn a sale price") $rdText)
  }

  # INSIDE THE WINDOW, OR AN EVERYDAY CLAIM: the price, and every per-unit reading of the store's figures.
  $oursCents = ConvertTo-TcCents $Claim.ad
  if ($null -ne $oursCents -and $oursCents -ne $shelf) {
    return (& $mk 'wrong-price' ("the store's shelf price is " + $shelfText + ", we publish " + ('$' + ('{0:0.00}' -f ([double]$oursCents / 100)))) $rdText)
  }
  $agree = 0; $disagree = 0
  foreach ($r in @($readings)) { if ([math]::Abs([int64]$r.key - $oursKey) -le 1) { $agree++ } else { $disagree++ } }
  foreach ($p in $printed) { if ($p.agree) { $agree++ } else { $disagree++ } }
  if (($agree + $disagree) -eq 0) {
    return (& $mk 'could-not-look' ("no reading of the store's figures (" + $shelfText + ", size '" + [string]$Answer.size + "') can be put in " + $Unit) $rdText)
  }
  if ($agree -eq 0) {
    return (& $mk 'wrong-price' ("no reading of the store's own figures gives our " + ('{0:0.0000}' -f $oursPu) + '/' + $Unit + ': ' + ($rdText -join '; ')) $rdText)
  }
  if ($disagree -gt 0) {
    return (& $mk 'could-not-look' ("the store's own figures disagree with each other (" + ($rdText -join '; ') + "), so its answer settles nothing") $rdText)
  }
  if ($idBlind) { return (& $mk 'could-not-look' 'the price agrees but identity could not be tested (matcher time bound)' $rdText) }
  return (& $mk 'match' ("the store's read of " + [string]$Answer.as_of + ' reproduces it: ' + ($rdText -join '; ')) $rdText)
}

# ---- THE LEDGER -------------------------------------------------------------------------------------------------------

function Get-TcClaimKey($Cell) {
  # WHICH CLAIM: the product and its published per-unit. Deliberately nothing else, so the live row, the flag's copy of it
  # and the candidate an applied quarantine held back (bad_item / bad_per_unit) all key the same way.
  if ($null -eq $Cell) { return '' }
  $pu = 0.0; try { $pu = [double]$Cell.per_unit } catch { $pu = 0.0 }
  return ((([string]$Cell.item).Trim().ToLower()) + '|' + (ConvertTo-TcPuKey $pu))
}

function Get-TcBoardCellIndex($Board) {
  # id|store -> { cell; commodity; unit; published_claim }. published_claim is what the PIPELINE produced for the cell:
  # the live row, or, for a cell an applied quarantine holds, the candidate it held back (bad_item / bad_per_unit), so a
  # disagreement stays open for as long as the pipeline keeps producing the contradicted claim.
  $ix = @{}
  foreach ($r in @($Board.comparison)) {
    if ($null -eq $r) { continue }
    foreach ($s in @($r.stores)) {
      if ($null -eq $s) { continue }
      $ix[[string]$r.id + '|' + [string]$s.store] = [pscustomobject]@{ cell = $s; commodity = [string]$r.commodity; unit = [string]$r.unit; published_key = (Get-TcClaimKey $s) }
    }
  }
  if ($Board.PSObject.Properties['quarantine'] -and $Board.quarantine) {
    foreach ($e in @($Board.quarantine.cells)) {
      if ($null -eq $e) { continue }
      $k = [string]$e.id + '|' + [string]$e.store
      $bad = [pscustomobject]@{ item = [string]$e.bad_item; per_unit = $e.bad_per_unit }
      if ($ix.ContainsKey($k)) { $ix[$k] | Add-Member -NotePropertyName held_key -NotePropertyValue (Get-TcClaimKey $bad) -Force }
      else { $ix[$k] = [pscustomobject]@{ cell = $null; commodity = ''; unit = ''; published_key = ''; held_key = (Get-TcClaimKey $bad) } }
    }
  }
  return $ix
}

function New-TcFlagLedger { return [pscustomobject]@{ generated = ''; entries = [ordered]@{}; closed = @() } }

function ConvertTo-TcLedgerEntries($Ledger) {
  # entries as a hashtable keyed id|store, whatever shape the JSON reader gave back
  $h = [ordered]@{}
  if ($null -eq $Ledger -or $null -eq $Ledger.entries) { return $h }
  if ($Ledger.entries -is [System.Collections.IDictionary]) { foreach ($k in $Ledger.entries.Keys) { $h[[string]$k] = $Ledger.entries[$k] } }
  else { foreach ($p in $Ledger.entries.PSObject.Properties) { $h[[string]$p.Name] = $p.Value } }
  return $h
}

function New-TcFlagEntry($Flag, [string]$Today) {
  $claim = [pscustomobject]@{
    item = [string]$Flag.item; per_unit = $Flag.per_unit; ad = [string]$Flag.ad; size = [string]$Flag.size
    row_type = [string]$Flag.row_type; ad_from = [string]$Flag.ad_from; ad_to = [string]$Flag.ad_to; as_of = [string]$Flag.as_of
  }
  return [pscustomobject]@{
    key = ([string]$Flag.id + '|' + [string]$Flag.store); id = [string]$Flag.id; commodity = [string]$Flag.commodity; store = [string]$Flag.store
    unit = [string]$Flag.unit; claim = $claim; claim_key = (Get-TcClaimKey $claim); flag_types = @([string]$Flag.type)
    first_flagged = $Today; last_flagged = $Today; status = 'pending'; reason = ''; verdict_at = ''; answer = $null
    attempts = 0; last_attempt = ''; alerted_at = ''; closed_at = ''; readings = @()
  }
}

function Update-TcFlagLedger {
  <#
    One pass. Returns { ledger; changes } where changes lists what moved this run.
      1. Every OPEN entry whose claim the pipeline no longer produces closes: left-board (no such cell) or claim-changed.
         Neither is a verdict and neither is ever reported as one; both are counted every run.
      2. Every paging flag with a named cell opens a pending entry, unless an open entry already holds that claim (then
         it is refreshed) or the cell is held by an applied quarantine (its question is already open).
      3. Every open entry is put to the store: $Resolve is a scriptblock (entry -> verdict object) supplied by the
         caller, so this function stays pure and a fixture can answer for the store.
         match closes; wrong-price / wrong-product stay open (the audit quarantines them); could-not-look stays pending.
         A disagreement is never downgraded by a later could-not-look.
  #>
  param($Ledger, $Flags, $Board, [string]$Today, [scriptblock]$Resolve)
  $entries = ConvertTo-TcLedgerEntries $Ledger
  $closed = New-Object System.Collections.ArrayList
  foreach ($c in @($Ledger.closed)) { if ($null -ne $c) { $d = ConvertTo-TcFvDay $c.closed_at; if ($null -eq $d -or ((ConvertTo-TcFvDay $Today) - $d).TotalDays -le $script:TcFlagClosedKeepDays) { [void]$closed.Add($c) } } }
  $changes = New-Object System.Collections.ArrayList
  $ix = Get-TcBoardCellIndex $Board
  $close = {
    param($e, [string]$why)
    $e.status = $why; $e.closed_at = $Today
    [void]$closed.Add($e); [void]$entries.Remove([string]$e.key)
    [void]$changes.Add([pscustomobject]@{ key = $e.key; change = $why })
  }
  foreach ($k in @($entries.Keys)) {
    $e = $entries[$k]
    $c = if ($ix.ContainsKey($k)) { $ix[$k] } else { $null }
    if ($null -eq $c) { & $close $e 'left-board'; continue }
    $still = ([string]$c.published_key -eq [string]$e.claim_key) -or ($c.PSObject.Properties['held_key'] -and [string]$c.held_key -eq [string]$e.claim_key)
    if (-not $still) { & $close $e 'claim-changed' }
  }
  foreach ($f in @($Flags)) {
    if ($null -eq $f) { continue }
    $t = [string]$f.type
    if ($script:TcFlagQuietTypes -contains $t) { continue }
    if (-not $f.PSObject.Properties['store'] -or -not [string]$f.store -or -not [string]$f.id) { continue }
    $k = [string]$f.id + '|' + [string]$f.store
    $c = if ($ix.ContainsKey($k)) { $ix[$k] } else { $null }
    if ($null -ne $c -and $null -ne $c.cell -and $c.cell.PSObject.Properties['quarantine'] -and $c.cell.quarantine) { continue }
    $n = New-TcFlagEntry $f $Today
    if ($entries.Contains($k)) {
      $e = $entries[$k]
      if ([string]$e.claim_key -eq [string]$n.claim_key) {
        $e.last_flagged = $Today
        if (@($e.flag_types) -notcontains $t) { $e.flag_types = @(@($e.flag_types) + $t) }
        continue
      }
      & $close $e 'claim-changed'
    }
    $entries[$k] = $n
    [void]$changes.Add([pscustomobject]@{ key = $k; change = 'opened' })
  }
  foreach ($k in @($entries.Keys)) {
    $e = $entries[$k]
    $v = & $Resolve $e
    $e.attempts = 1 + [int]$e.attempts; $e.last_attempt = $Today
    if ($null -eq $v) { continue }
    $e.readings = @($v.readings)
    if ($v.PSObject.Properties['answer']) { $e.answer = $v.answer }
    switch ([string]$v.verdict) {
      'match' { $e.reason = [string]$v.reason; $e.verdict_at = $Today; & $close $e 'match' }
      'wrong-price' { if ($e.status -ne 'wrong-price') { $e.verdict_at = $Today; [void]$changes.Add([pscustomobject]@{ key = $k; change = 'wrong-price' }) }; $e.status = 'wrong-price'; $e.reason = [string]$v.reason }
      'wrong-product' { if ($e.status -ne 'wrong-product') { $e.verdict_at = $Today; [void]$changes.Add([pscustomobject]@{ key = $k; change = 'wrong-product' }) }; $e.status = 'wrong-product'; $e.reason = [string]$v.reason }
      'could-not-look' { if ($e.status -eq 'pending') { $e.reason = [string]$v.reason } }
      default { throw ('unknown flag verdict: ' + [string]$v.verdict) }
    }
  }
  $L = [pscustomobject]@{ generated = $Today; entries = $entries; closed = $closed.ToArray() }
  return [pscustomobject]@{ ledger = $L; changes = $changes.ToArray() }
}

function Get-TcFlagQuarantineCells($Ledger, $Board) {
  # Every OPEN disagreement whose contradicted claim is still what the board PUBLISHES for that cell. A cell an applied
  # quarantine already holds publishes its last verified value instead, so it is not named again on the second guards
  # run; a withheld cell is gone from the board and is not named either.
  $ix = Get-TcBoardCellIndex $Board
  $out = New-Object System.Collections.ArrayList
  $entries = ConvertTo-TcLedgerEntries $Ledger
  foreach ($k in @($entries.Keys)) {
    $e = $entries[$k]
    if (@('wrong-price', 'wrong-product') -notcontains [string]$e.status) { continue }
    if (-not $ix.ContainsKey($k)) { continue }
    $c = $ix[$k]
    if ($null -eq $c.cell) { continue }
    if ($c.cell.PSObject.Properties['quarantine'] -and $c.cell.quarantine) { continue }
    if ([string]$c.published_key -ne [string]$e.claim_key) { continue }
    [void]$out.Add([pscustomobject]@{ id = [string]$e.id; store = [string]$e.store; kind = 'value'; status = [string]$e.status; reason = [string]$e.reason })
  }
  return ,($out.ToArray())
}

function Get-TcFlagVerifyOwed {
  <#
    .SYNOPSIS Which commodities a store owes a re-read because a flagged cell of theirs is still PENDING verification.
    .DESCRIPTION Pure read of out\flag-verification.json. Empties itself: an entry leaves 'pending' only when a capture
      re-read it (match, wrong-*) or its claim left the board, so this list shrinks as captures land and must never be
      edited by hand. An unreadable ledger is BLIND and owes nothing it can name (the rotation still runs).
    .OUTPUTS @{ Ids (commodity ids); Items (the pending claims' own product names); Blind; Why }
  #>
  param([string]$OutDir, [Parameter(Mandatory)][string]$Store)
  $none = [pscustomobject]@{ Ids = @(); Items = @(); Blind = $false; Why = '' }
  $f = Join-Path $OutDir $script:TcFlagLedgerName
  if (-not (Test-Path -LiteralPath $f)) { return $none }
  $doc = $null
  try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText($f)) } catch { $doc = $null }
  if ($null -eq $doc) { return [pscustomobject]@{ Ids = @(); Items = @(); Blind = $true; Why = ($script:TcFlagLedgerName + ' is present but unparseable, so what it owes is unknown') } }
  $entries = ConvertTo-TcLedgerEntries $doc
  $ids = New-Object System.Collections.ArrayList
  $items = New-Object System.Collections.ArrayList
  foreach ($k in @($entries.Keys)) {
    $e = $entries[$k]
    if ([string]$e.status -ne 'pending' -or [string]$e.store -ne $Store) { continue }
    if (-not ($ids -contains [string]$e.id)) { [void]$ids.Add([string]$e.id) }
    $it = ''; if ($null -ne $e.claim) { $it = ([string]$e.claim.item).Trim() }
    if ($it -and -not ($items -contains $it)) { [void]$items.Add($it) }
  }
  return [pscustomobject]@{ Ids = $ids.ToArray(); Items = $items.ToArray(); Blind = $false; Why = '' }
}

function Invoke-TcDisagreementAlerts {
  <#
    ONE alert per disagreeing cell, ONCE. An entry is stamped alerted_at only when ITS send succeeded, so a failed send
    or a -NoAlert run leaves it DUE for the next alerting run: a clock is never advanced by something that was not a page
    (check-ad-cycles' 2026-07-30 rule for the old flag pager, kept). $Send is a scriptblock (subject, body) -> $true when
    the alert went out, so check-ad-cycles hands in Send-Alert and a fixture hands in a recorder. Returns the counts; the
    caller writes the ledger back, because the stamps land on the ledger's own entry objects.
  #>
  param($Ledger, [scriptblock]$Send, [switch]$NoAlert, [string]$Today)
  $entries = ConvertTo-TcLedgerEntries $Ledger
  $sent = 0; $due = 0; $failed = 0
  foreach ($k in @($entries.Keys)) {
    $e = $entries[$k]
    if (@('wrong-price', 'wrong-product') -notcontains [string]$e.status) { continue }
    if ([string]$e.alerted_at) { continue }
    $due++
    if ($NoAlert) { continue }
    $a = Format-TcDisagreementAlert $e
    $ok = $false
    try { $ok = [bool](& $Send $a.subject $a.body) } catch { $ok = $false }
    if ($ok) { $e.alerted_at = $Today; $sent++ } else { $failed++ }
  }
  return [pscustomobject]@{ sent = $sent; due = $due; failed = $failed }
}

function Format-TcDisagreementAlert($Entry) {
  # ONE alert per disagreeing cell. The subject names the cell, so the queue keys the type by cell and a return means
  # that very cell came back. The body names both prices and the store's own product.
  $a = $Entry.answer
  $sp = if ($null -ne $a) { [string]$a.current_price } else { '' }
  if ($sp -and $sp -notmatch '^\$') { $sp = '$' + $sp }
  $subject = 'Grocery: price disagreement - ' + [string]$Entry.commodity + ' at ' + [string]$Entry.store
  $ours = ('$' + ('{0:0.0000}' -f [double]$Entry.claim.per_unit) + '/' + [string]$Entry.unit)
  $body = @(
    ([string]$Entry.store + ' says ' + $sp + " for '" + $(if ($a) { [string]$a.item } else { '' }) + "' (" + $(if ($a) { [string]$a.size } else { '' }) + ', read ' + $(if ($a) { [string]$a.as_of } else { '' }) + '); we publish ' + $ours + " for '" + [string]$Entry.claim.item + "'" + $(if ([string]$Entry.claim.ad) { ' (' + [string]$Entry.claim.ad + $(if ([string]$Entry.claim.size) { ', ' + [string]$Entry.claim.size } else { '' }) + ')' } else { '' }) + '.'),
    ('Verdict: ' + [string]$Entry.status + ' - ' + [string]$Entry.reason),
    ('Cell: ' + [string]$Entry.key + ' (' + [string]$Entry.commodity + '). It is quarantined by guards (audit-flag-verification.ps1) at its last verified published price, or withheld, for as long as the pipeline keeps producing this claim.'),
    ('Flag(s) that raised it: ' + (@($Entry.flag_types) -join ', ') + ', first flagged ' + [string]$Entry.first_flagged + '. Ledger: grocery/out/flag-verification.json.')
  ) -join "`n"
  return [pscustomobject]@{ subject = $subject; body = $body }
}
