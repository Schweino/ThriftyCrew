# row-contract-lib.ps1 - THE CAPTURE ROW CONTRACT (build step 8, ruling 2): one validator, pure functions.
# ---------------------------------------------------------------------------------------------------
# SPEC: design/SPEC-capture-row-contract.md. Plan: design/PLAN-weekly-root-families-2026-10-02.md Phase 2,
# design/PLAN-zero-alert-days-remainder-2026-09-24.md step 8. Brad's D1 ruling (2026-10-02): SHADOW now, refusing
# nothing and moving no price; enforcement per store only after that store's capture work (R18, R11) has landed.
#
# WHAT IT ANSWERS. Given ONE captured row and its commodity's declarations, it states the row's size (value, unit,
# KIND), pack count, price basis and deal terms, each with the FIELD it was read from, and a REFUSAL CODE for every
# field it cannot prove. It decides nothing about matching, bands or the board.
#
# IT IS NOT A THIRD READER. The defect it exists for is two readers of one token (queue 2026-10-02-44c416: the engine's
# Convert-ToUnit reads "fl oz" as WEIGHT oz on an oz commodity while pu-lib's Get-SizeMeasureKind reads it as VOLUME).
# So every quantity here is read by the functions that already exist: Get-ItemPrice, Get-SizeAmount, Get-PackCount,
# Get-EachPackCount, Resolve-MultibuyPackCount, Get-EachCountConflict, Test-NameOffersTwoSizes, Get-TcDealCondition
# (pricing-math-lib.ps1) and Get-SizeMeasureKind (pu-lib.ps1). What this file adds is the DECISION those readings
# support, written once, with its source and its refusal code. The regexes below are shape tests on text (does a
# count read "8 or 10 ct", is a count "per pound"), never a second size or price parser.
#
# PURE: no file is read and nothing runs on load except the two dot-sources. The shadow audit
# (audit-row-contract-shadow.ps1) and later each builder call Get-TcRowContract.
#
# SCOPE OF A CLEAN REPORT: UNSOUND. A row the contract accepts can still be a wrong product or a wrong price; the
# contract only says its basis fields are proven. INCOMPLETE as a refusal: a refusal is a basis the row cannot PROVE,
# which is a candidate defect, not a proven one (gr-08: a card can be right and unprovable).
# ---------------------------------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'pricing-math-lib.ps1')
. (Join-Path $PSScriptRoot 'pu-lib.ps1')

# The refusal codes, one place. The spec's table is this list; test-row-contract.ps1 asserts each one fires.
function Get-TcRowContractCodes {
  return @(
    'NO-PRICE', 'DEAL-NO-REGULAR', 'NO-SIZE', 'SIZE-EITHER-OR',
    'KIND-VOLUME-ON-WEIGHT', 'KIND-WEIGHT-ON-VOLUME', 'KIND-LABELS-DISAGREE', 'KIND-COUNT-ON-MEASURE',
    'PACK-COUNT-AMBIGUOUS', 'PACK-BASIS-UNPROVEN', 'PACK-COUNT-UNSTATED', 'PACK-CONFLICT',
    'COUNT-UNSTATED', 'DEAL-COUNT-UNSTATED'
  )
}
# Codes where the contract PROVES a different basis than the engine reads (not a refusal; enforcement reprices).
function Get-TcRowContractRepriceCodes { return @('PACK-COUNT-IGNORED', 'PER-PIECE-PRICE-DIVIDED') }

# The KIND a commodity unit measures. catalog units today: lb oz floz gallon each dozen sq_ft.
function Get-TcUnitKind([string]$Unit) {
  switch -Regex (([string]$Unit).Trim().ToLower()) {
    '^(lb|oz)$'         { return 'weight' }
    '^(floz|gallon)$'   { return 'volume' }
    '^(each|dozen)$'    { return 'count' }
    '^sq_ft$'           { return 'area' }
    default             { return 'unknown' }   # an unknown unit is reported, never guessed
  }
}

# A commodity's density declaration (Get-TcCommodityDensity) and the number the arithmetic uses (Get-TcDensityGml) live in
# pricing-math-lib.ps1 since 2026-10-03 (R7.4), so this contract and the engine's Get-UnitPrice read ONE declaration.

function Get-TcContractProp($Obj, [string]$Name) {
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [hashtable] -or $Obj -is [System.Collections.Specialized.OrderedDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] }; return $null }
  $pp = $Obj.PSObject.Properties[$Name]
  if ($pp) { return $pp.Value }
  return $null
}

# ONE ROW SHAPE IN. The engine's candidate row (name / price_text / size_text) and the builders' output row
# (item / ad_price / size) carry the same three source texts under different names; this maps the second onto the
# first and keeps the fields the contract reads as evidence (store unit price proof, markdown, sale window).
function ConvertTo-TcContractRow($Row) {
  $name = Get-TcContractProp $Row 'name'; if ($null -eq $name) { $name = Get-TcContractProp $Row 'item' }
  $pt = Get-TcContractProp $Row 'price_text'; if ($null -eq $pt) { $pt = Get-TcContractProp $Row 'ad_price' }
  $sz = Get-TcContractProp $Row 'size_text'; if ($null -eq $sz) { $sz = Get-TcContractProp $Row 'size' }
  $proof = ''
  $qb = [string](Get-TcContractProp $Row 'qty_basis')
  if ($qb -match '(?i)reproduces') { $proof = 'qty_basis: ' + $qb }
  if (-not $proof -and (Get-TcContractProp $Row 'sams_unit_price_proven')) { $proof = 'sams_unit_price_proven' }
  return [ordered]@{
    store          = [string](Get-TcContractProp $Row 'store')
    name           = [string]$name
    price_text     = [string]$pt
    size_text      = [string]$sz
    regular        = (Get-TcContractProp $Row 'regular')
    price_type     = [string](Get-TcContractProp $Row 'price_type')
    split_from     = (Get-TcContractProp $Row 'split_from')
    marked_down    = (Get-TcContractProp $Row 'marked_down')
    sale_ends_days = (Get-TcContractProp $Row 'sale_ends_days')
    ad_to          = [string](Get-TcContractProp $Row 'ad_to')
    unit_proof     = $proof
  }
}

function Test-TcNear([double]$a, [double]$b, [double]$tol) {
  if ($b -eq 0) { return ($a -eq 0) }
  return ([math]::Abs($a - $b) / [math]::Abs($b) -le $tol)
}

# THE FIRST SINGLE MEASURE A TEXT STATES, read by Get-SizeAmount on that token alone, so a pack multiplier elsewhere
# in the text never enters it. $null when the text names no weight or volume.
function Get-TcSingleMeasure([string]$Text, [string]$Unit, [double]$DensityGml = 0) {
  if (-not $Text) { return $null }
  $m = [regex]::Match($Text.ToLower(), '(\d+(?:\.\d+)?|\.\d+)\s*-?\s*(fl\.?\s*oz|floz|oz|ounces?|lbs?|pounds?|gal|gallons?|qt|quarts?|pt|pints?|liters?|litres?|ltr|ml|g|grams?)\b')
  if (-not $m.Success) { return $null }
  return (Get-SizeAmount ($m.Groups[1].Value + ' ' + ($m.Groups[2].Value -replace '\.', '')) $Unit $DensityGml)
}

# A count that is PER A CONTAINER OR A WEIGHT is a grade, not a pack: "21-25 ct. per pound", "24 ct. per box"
# (queue 2026-09-29-1eac5a). Returns the matched phrase or ''.
function Get-TcCountPerContainer([string]$Text) {
  $m = [regex]::Match(([string]$Text).ToLower(), '(?<![\d.$])\d+(?:\s*(?:-|to)\s*\d+)?\s*(?:ct|count)\.?\s*(?:per|/)\s*(?:pound|lb|box|bag|pkg|package|tray|case)\b')
  if ($m.Success) { return $m.Value }
  return ''
}
# A count offered as an ALTERNATIVE ("8 or 10 ct.") names two products, never one pack (queue 2026-09-28-9ee1f9).
function Test-TcCountAlternative([string]$Text) {
  return ([regex]::IsMatch(([string]$Text).ToLower(), '(?<![\d.$])\d+\s*or\s*\d+\s*(?:ct|count|pk|pack)\b'))
}
# A count RANGE ("11-15 ct.", "6 to 12 ct") states how many pieces a bag holds, never a multiplier of a size.
function Test-TcCountRange([string]$Text) {
  return ([regex]::IsMatch(([string]$Text).ToLower(), '(?<![\d.$])\d+\s*(?:-|to|thru)\s*\d+\s*(?:ct|count)\b'))
}

function New-TcContractField($Value, [string]$Source) { return [ordered]@{ value = $Value; source = $Source } }

# THE VALIDATOR. $Row: a candidate or builder row (ConvertTo-TcContractRow is applied here). $Commodity: the catalog
# entry (id, unit, and the declarations weight_is_one_unit, pack_is_package, pint_oz, kind_equivalent). -KindReviewed:
# the cell's size string is reviewed in basis-kind-allowlist.json (the number is right; only its label disagrees).
function Get-TcRowContract {
  param($Row, $Commodity, [switch]$KindReviewed)
  $r = ConvertTo-TcContractRow $Row
  $unit = [string](Get-TcContractProp $Commodity 'unit')
  $ckind = Get-TcUnitKind $unit
  $refuse = New-Object 'System.Collections.Generic.List[object]'
  $reprice = New-Object 'System.Collections.Generic.List[object]'
  $out = [ordered]@{
    unit = $unit; unit_kind_commodity = $ckind
    price = $null; size = $null; unit_kind = $null; pack = $null; price_basis = $null; deal = $null
    refusals = $refuse; reprice = $reprice; verdict = 'accept'
  }
  function _Refuse([string]$code, [string]$field, [string]$why) { $refuse.Add([ordered]@{ code = $code; field = $field; why = $why }) }

  # ---- PRICE and DEAL TERMS ---------------------------------------------------------------------------------
  $pr = Get-ItemPrice $r.price_text $r.name $r.regular
  $isMulti = Test-IsMultibuy $r.price_text
  if ($null -eq $pr) {
    if ($isMulti -and ($null -eq $r.regular -or [string]$r.regular -eq '')) { _Refuse 'DEAL-NO-REGULAR' 'deal' 'a buy-N-get-K price needs the regular price, and the row carries none' }
    else { _Refuse 'NO-PRICE' 'price' 'no money token in the price text or the name' }
    $out.verdict = 'refuse'
    return $out
  }
  $plain = ([string]$pr.note -eq '' -or [string]$pr.note -eq 'cents')
  $out.price = New-TcContractField ([double]$pr.per_item) $(if ($pr.note) { 'price_text (' + $pr.note + ')' } else { 'price_text' })
  $dc = Get-TcDealCondition $r.price_text ([string]$pr.note)
  $dealKind = 'none'; $dealSrc = ''; $dealQty = $null
  if ($dc) { $dealKind = [string]$dc.kind; $dealQty = $dc.qty; $dealSrc = 'price_text' }
  $md = $false
  if ($r.marked_down -eq $true -or [string]$r.marked_down -eq 'True') { $md = $true; if (-not $dealSrc) { $dealSrc = 'marked_down' } }
  $regN = 0.0
  if (-not $md -and $plain -and $r.regular -ne $null -and [double]::TryParse(([string]$r.regular -replace '[$,]', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$regN) -and $regN -gt ([double]$pr.per_item + 0.005)) { $md = $true; if (-not $dealSrc) { $dealSrc = 'regular > price' } }
  if ($md -and $dealKind -eq 'none') { $dealKind = 'markdown' }
  $ttl = $null
  if ($r.sale_ends_days -ne $null -and [string]$r.sale_ends_days -ne '') { $ttl = 'ends in ' + [string]$r.sale_ends_days + ' day(s) (sale_ends_days)' }
  elseif ($r.ad_to) { $ttl = 'ends ' + $r.ad_to + ' (ad_to)' }
  $out.deal = [ordered]@{ kind = $dealKind; qty = $dealQty; ttl = $ttl; source = $(if ($dealSrc) { $dealSrc } else { 'none stated' }) }

  $perEach = [bool]$pr.kind.pereach; $perLb = [bool]$pr.kind.perlb
  $twoSizes = (Test-NameOffersTwoSizes $r.name) -and -not $r.split_from
  $cpc = (Get-TcCountPerContainer ($r.name + ' ' + $r.size_text))

  if ($ckind -eq 'weight' -or $ckind -eq 'volume' -or $ckind -eq 'area' -or $unit -eq 'dozen') {
    # ---- SIZE: the size field first, the name only when the field states no usable amount (the engine's order) ----
    $src = 'none'; $txt = ''; $amt = $null
    # THE ENGINE'S DENSITY, read the engine's way (R7.4): a numeric density_g_ml converts a volume size to the weight
    # unit, except on a row whose name states the same number as a weight (Test-TcKindLabelsDisagree), so the size
    # value here is the quantity Get-UnitPrice divides by.
    $dgNum = Get-TcDensityGml $Commodity
    $dgBlocked = ($dgNum -gt 0) -and (Test-TcKindLabelsDisagree $r.size_text $r.name $unit)
    $dg = if ($dgBlocked) { 0.0 } else { $dgNum }
    $a1 = Get-SizeAmount $r.size_text $unit $dg
    if ($null -ne $a1 -and $a1 -gt 0) { $src = 'size_text'; $txt = $r.size_text; $amt = $a1 }
    elseif (-not $twoSizes) {
      $a2 = Get-SizeAmount $r.name $unit $dg
      if ($null -ne $a2 -and $a2 -gt 0) { $src = 'name'; $txt = $r.name; $amt = $a2 }
    }
    # a pint_oz declaration converts a bare dry pint to a weight (blueberries); the engine does the same
    $pint = Get-TcContractProp $Commodity 'pint_oz'
    $kind = if ($txt) { Get-SizeMeasureKind -Size $txt -Unit $unit } else { Get-SizeMeasureKind -Size $r.size_text -Unit $unit }
    if ($pint -and $ckind -eq 'weight' -and $txt -match '(?i)\b(pt|pint)s?\b' -and $txt -notmatch '(?i)\b(oz|lb|g|gram)') { $kind = 'weight'; $src = $src + ' via commodity.pint_oz' }
    $out.size = [ordered]@{ value = $amt; unit = $unit; text = $txt; source = $src }
    $out.unit_kind = New-TcContractField $kind $(if ($txt) { $src } else { 'size_text' })

    $rateOnly = ($null -eq $amt) -and ($perLb -and $ckind -eq 'weight')
    # the engine's 'per-lb rate in size' shape: Hy-Vee random weight, size ' lbs ($9.99/lb)' with the price EQUAL to that rate
    $slb = [regex]::Match([string]$r.size_text, '\(\s*\$\s*(\d+(?:\.\d+)?)\s*/\s*lb\.?\s*\)')
    $rateInSize = ($unit -eq 'lb' -and $plain -and $slb.Success -and [math]::Abs([double]$slb.Groups[1].Value - [double]$pr.per_item) -lt 0.005)
    if ($rateInSize) { $rateOnly = $true; $amt = 1.0; $src = 'size_text per-lb rate'; $kind = 'weight'; $out.size = [ordered]@{ value = 1.0; unit = $unit; text = $r.size_text; source = $src }; $out.unit_kind = New-TcContractField 'weight' $src }
    if ($twoSizes -and $null -eq $a1) { _Refuse 'SIZE-EITHER-OR' 'size' 'the name offers two sizes and the size field states none' }
    elseif ($null -eq $amt -and -not $rateOnly) {
      if ((Get-SizeMeasureKind -Size $r.size_text -Unit $unit) -eq 'count') { _Refuse 'KIND-COUNT-ON-MEASURE' 'unit_kind' ('the size states a count (' + $r.size_text + ') and nothing states a ' + $ckind) }
      else { _Refuse 'NO-SIZE' 'size' ('no ' + $ckind + ' amount in the size field or the name') }
    }
    if ($null -ne $amt) {
      $dens = Get-TcCommodityDensity $Commodity
      # the NAME may state the commodity's own kind at the SAME amount as a size field labelled the other kind
      # (Sam's 'Member's Mark Olive Oil Cooking Spray, 7 oz., 2 pk.' with size '14 fl oz': 7 x 2 = 14 weight oz)
      if (($ckind -eq 'weight' -and $kind -eq 'volume') -or ($ckind -eq 'volume' -and $kind -eq 'weight')) {
        $nAmt = Get-SizeAmount $r.name $unit
        # A NUMERIC density does not settle this (R7.4): the name says the number is a weight already, so converting it
        # would be a guess too. Only near-water (interchangeable units) and a reviewed size string still silence it.
        if (((-not $dens) -or $dgBlocked) -and -not $KindReviewed -and $src -eq 'size_text' -and -not $twoSizes -and $null -ne $nAmt -and (Get-SizeMeasureKind -Size $r.name -Unit $unit) -eq $ckind -and (Test-TcNear $amt $nAmt 0.01)) {
          # NOT an acceptance: the size field and the name are two parties stating two KINDS for one number, and a store
          # name that drops "fl" off a liquid is as common as a builder that adds it. Its own code, so a ruling can take it.
          _Refuse 'KIND-LABELS-DISAGREE' 'unit_kind' ('the size field says ' + $txt + ' (' + $kind + ') and the name states ' + $nAmt + ' ' + $unit + ' as a ' + $ckind + '; nothing proves which')
          $kind = 'disputed'; $out.unit_kind.value = 'disputed'
        }
      }
      if ($ckind -eq 'weight' -and $kind -eq 'volume') {
        if ($dens) { $out.unit_kind.source = $out.unit_kind.source + '; volume accepted by ' + $dens.source + $(if ($dg -gt 0) { ' (converted at ' + $dg.ToString([Globalization.CultureInfo]::InvariantCulture) + ' g/ml)' } else { '' }) }
        elseif ($KindReviewed) { $out.unit_kind.source = $out.unit_kind.source + '; reviewed in basis-kind-allowlist.json' }
        else { _Refuse 'KIND-VOLUME-ON-WEIGHT' 'unit_kind' ('a volume size (' + $txt + ') on a ' + $unit + ' commodity that declares no density') }
      }
      if ($ckind -eq 'volume' -and $kind -eq 'weight') {
        if ($dens) { $out.unit_kind.source = $out.unit_kind.source + '; weight accepted by ' + $dens.source }
        elseif ($KindReviewed) { $out.unit_kind.source = $out.unit_kind.source + '; reviewed in basis-kind-allowlist.json' }
        else { _Refuse 'KIND-WEIGHT-ON-VOLUME' 'unit_kind' ('a weight size (' + $txt + ') on a ' + $unit + ' commodity that declares no density') }
      }
      # ---- PACK COUNT on a measure row ----
      $single = Get-TcSingleMeasure $txt $unit $dg
      $txtNoGrade = if ($cpc) { $txt.ToLower().Replace($cpc, ' ') } else { $txt }
      if ($cpc) {
        $out.pack = [ordered]@{ count = 1; form = 'count-per-container'; source = 'name: ' + $cpc.Trim() }
      } elseif ((Test-TcCountAlternative $txtNoGrade) -and $single -and -not (Test-TcNear $amt $single 0.001)) {
        $out.pack = [ordered]@{ count = $null; form = 'either-or'; source = $src }
        _Refuse 'PACK-COUNT-AMBIGUOUS' 'pack' ('the count is offered as an alternative and the size read multiplies it: ' + $amt + ' ' + $unit + ' from a ' + $single + ' ' + $unit + ' item')
      } elseif ((Test-TcCountRange $txtNoGrade) -and $single -and -not (Test-TcNear $amt $single 0.001)) {
        $out.pack = [ordered]@{ count = $null; form = 'range'; source = $src }
        _Refuse 'PACK-COUNT-AMBIGUOUS' 'pack' ('a piece-count range was read as a pack multiplier: ' + $amt + ' ' + $unit + ' from a ' + $single + ' ' + $unit + ' item')
      } else {
        # who states a pack count: a volume row counts containers (ct, count, ea, pk, pack); on a weight row a bare
        # 'ct' is pieces inside one package (nuggets, links), so only an explicit pk/pack is a multipack.
        $cnt = $null; $cntFrom = ''
        foreach ($party in @(@('size_text', $r.size_text), @('name', $r.name), @('price_text', $r.price_text))) {
          $t = [string]$party[1]; if (-not $t) { continue }
          if ($party[0] -ne 'size_text' -and (Test-NameOffersTwoSizes $t)) { continue }
          $n = $null
          if ($kind -eq 'volume') { $n = Get-PackCount $t }
          else { $wm = [regex]::Match($t.ToLower(), '(?<![\d.$])(\d+)\s*-?\s*(?:pk|pack)\b'); if ($wm.Success -and [int]$wm.Groups[1].Value -gt 1) { $n = [int]$wm.Groups[1].Value } }
          if ($n) { $cnt = $n; $cntFrom = $party[0]; break }
        }
        $nameSingle = Get-TcSingleMeasure $r.name $unit $dg
        if ($cnt -and $cnt -gt 1) {
          $form = 'pack'
          if ($nameSingle -and (Test-TcNear $amt ($cnt * $nameSingle) 0.03)) {
            $out.pack = [ordered]@{ count = $cnt; form = $form; source = $cntFrom + '; size is the pack total (' + $cnt + ' x ' + $nameSingle + ')' }
          } elseif ($nameSingle -and (Test-TcNear $amt $nameSingle 0.03)) {
            if ($r.unit_proof) {
              $out.pack = [ordered]@{ count = $cnt; form = $form; source = $cntFrom + '; basis proven by the store unit price (' + $r.unit_proof + ')' }
            } elseif ((Get-SizeMeasureKind -Size $r.size_text -Unit $unit) -eq 'count' -and (Get-PackCount $r.size_text) -eq $cnt) {
              $out.pack = [ordered]@{ count = $cnt; form = $form; source = 'size_text states the count, the name the item size' }
              $reprice.Add([ordered]@{ code = 'PACK-COUNT-IGNORED'; field = 'pack'; why = ('size_text states ' + $cnt + ' and the name ' + $nameSingle + ' ' + $unit + ' each, so the pack is ' + ($cnt * $nameSingle) + ' ' + $unit + '; a reader dividing by ' + $amt + ' ignores the count') })
            } else {
              $out.pack = [ordered]@{ count = $cnt; form = 'unproven'; source = $cntFrom }
              _Refuse 'PACK-BASIS-UNPROVEN' 'pack' ($cntFrom + ' states ' + $cnt + ' and the size equals one item (' + $amt + ' ' + $unit + '); nothing proves whether the price is for one or the pack (gr-08)')
            }
          } else {
            $out.pack = [ordered]@{ count = $cnt; form = $form; source = $cntFrom + '; size is a package measure' }
          }
        } else {
          $out.pack = [ordered]@{ count = 1; form = 'single'; source = 'no count stated' }
          if ($kind -eq 'volume' -and -not $r.unit_proof -and ([regex]::IsMatch($r.name.ToLower(), '\b(cans|bottles)\b'))) {
            $out.pack.form = 'unstated'
            _Refuse 'PACK-COUNT-UNSTATED' 'pack' 'the name sells plural containers and no party states how many'
          }
        }
      }
    }
    # ---- PRICE BASIS on a measure row ----
    if ($rateOnly) { $out.price_basis = New-TcContractField 'per-unit' 'price_text per-lb marker' }
    elseif (-not $plain) { $out.price_basis = New-TcContractField 'deal' ('price_text: ' + $pr.note) }
    elseif ($out.pack -and $out.pack.count -gt 1) { $out.price_basis = New-TcContractField 'pack-total' $out.pack.source }
    else { $out.price_basis = New-TcContractField 'item' 'price_text' }
  }
  elseif ($ckind -eq 'count') {
    $kind = Get-SizeMeasureKind -Size $r.size_text -Unit $unit
    $out.unit_kind = New-TcContractField $kind 'size_text'
    $out.size = [ordered]@{ value = $null; unit = $unit; text = $r.size_text; source = 'size_text' }
    $isPkg = [bool](Get-TcContractProp $Commodity 'pack_is_package')
    $woU = [bool](Get-TcContractProp $Commodity 'weight_is_one_unit')
    # the pack count, by the engine's own reader and order: price text (unless either/or), size field, name (unless either/or)
    $pk = $null; $pkFrom = ''
    if (-not $cpc) {
      if (-not (Test-NameOffersTwoSizes $r.price_text)) { $pk = Get-EachPackCount $r.price_text; if ($pk) { $pkFrom = 'price_text' } }
      if (-not $pk) { $pk = Get-EachPackCount $r.size_text; if ($pk) { $pkFrom = 'size_text' } }
      if ((-not $pk) -and -not (Test-NameOffersTwoSizes $r.name)) { $pk = Get-EachPackCount $r.name; if ($pk) { $pkFrom = 'name' } }
    }
    $wholeSize = ([string]$r.size_text -match ('(?i)^\s*(1\s*)?(' + (Get-TcWholePurchaseTokens) + ')\.?\s*$'))
    $eachInPrice = ((ConvertTo-DigitNumerals ([string]$r.price_text)) -match '(?i)\$\s*\d+(?:\.\d+)?\s*(?:/\s*)?(?:ea|each)\b|\d+(?:\.\d+)?\s*each\b')
    $weightSize = ([string]$r.size_text -match '(?i)(\d+(?:\.\d+)?|\.\d+)\s*(oz|ounce|ounces|lb|lbs|pound|pounds|g|gram|grams)\b')
    if (-not $plain) {
      $mb = Resolve-MultibuyPackCount ([pscustomobject]@{ price_text = $r.price_text; size_text = $r.size_text; name = $r.name })
      if ($mb.conflict) { _Refuse 'PACK-CONFLICT' 'pack' ('the parties state different counts: ' + $mb.from) }
      elseif ($mb.count) { $pk = [int]$mb.count; $pkFrom = $mb.from }
    } elseif ($pk) {
      $cf = Get-EachCountConflict $r.size_text $r.name (Get-EachPackCount $r.size_text)
      if ($cf) { _Refuse 'PACK-CONFLICT' 'pack' $cf }
    }
    if ($pk -and $isPkg) {
      $out.pack = [ordered]@{ count = $pk; form = 'package'; source = $pkFrom + '; commodity.pack_is_package: the package is the unit, ' + $pk + ' pieces inside' }
      $out.price_basis = New-TcContractField 'per-package' 'commodity.pack_is_package'
    } elseif ($pk) {
      $out.pack = [ordered]@{ count = $pk; form = 'pack'; source = $pkFrom }
      $out.price_basis = New-TcContractField 'pack-total' $pkFrom
      if ($plain -and $eachInPrice) {
        # "$0.99 each" beside a count: per PIECE only when another stated amount is that count times the price
        $amts = @([regex]::Matches((ConvertTo-DigitNumerals ($r.price_text + ' ' + $r.name)), '(?<![\d.])(\d+\.\d{2})(?!\d)') | ForEach-Object { [double]$_.Groups[1].Value })
        $proofAmt = @($amts | Where-Object { (Test-TcNear $_ ($pk * [double]$pr.per_item) 0.03) -and -not (Test-TcNear $_ ([double]$pr.per_item) 0.001) })
        if ($proofAmt.Count -gt 0) {
          $out.price_basis = New-TcContractField 'per-piece' ('price_text: ' + $pk + ' x ' + $pr.per_item + ' = ' + $proofAmt[0] + ' is stated')
          $reprice.Add([ordered]@{ code = 'PER-PIECE-PRICE-DIVIDED'; field = 'price_basis'; why = ('the line states the pack at ' + $proofAmt[0] + ', so ' + $pr.per_item + ' is already per piece; dividing it by ' + $pk + ' again understates it') })
        }
      }
    } else {
      $out.pack = [ordered]@{ count = 1; form = 'single'; source = '' }
      if ($wholeSize) { $out.pack.source = 'size_text names one purchase (' + $r.size_text + ')' }
      elseif ($eachInPrice -or ($perEach -and $plain)) { $out.pack.source = 'price_text per-each marker' }
      elseif ($woU -and ($weightSize -or ($r.name -match '(?i)\d\s*(oz|lb|g)\b'))) { $out.pack.source = 'commodity.weight_is_one_unit' }
      elseif ($cpc) { $out.pack.source = 'name: ' + $cpc.Trim() }
      elseif (-not $plain) {
        $out.pack.form = 'unstated'
        _Refuse 'DEAL-COUNT-UNSTATED' 'pack' ('a ' + $dealKind + ' deal on an each-unit commodity, and no party states how many pieces one unit holds')
      } elseif (([string]$r.price_text) -match '(?i)perks\s*price') { $out.pack.source = 'Hy-Vee Perks single retail unit' }
      else {
        $out.pack.form = 'unstated'
        _Refuse 'COUNT-UNSTATED' 'pack' 'a package price with no count, no whole-purchase size and no per-each marker'
      }
      $out.price_basis = New-TcContractField $(if ($plain) { 'item' } else { 'deal' }) $(if ($plain) { 'price_text' } else { 'price_text: ' + $pr.note })
    }
  }
  else {
    $out.unit_kind = New-TcContractField 'unknown' ('commodity unit ' + $unit + ' is not one the contract knows')
  }
  if ($refuse.Count -gt 0) { $out.verdict = 'refuse' } elseif ($reprice.Count -gt 0) { $out.verdict = 'reprice' }
  return $out
}
