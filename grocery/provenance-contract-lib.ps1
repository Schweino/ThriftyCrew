<#
  provenance-contract-lib.ps1 - WHAT A CAPTURED PRICE MUST PROVE BEFORE IT MAY PUBLISH (2026-09-19)

  THE FOUNDING MEASUREMENT. The blind verification of the 2026-09-17 board found 36 defects in 100 verified
  cells (whole-board 37.1%, 95% CI 24.2% to 52.0%). 24 of the 36 were one design flaw: the board published a
  captured price unless something proved it wrong, and nothing required it to prove WHEN it was read, WHERE,
  or that a shopper could BUY it there. design\PLAN-board-accuracy-2026-09-19.md has every defect.
    - WHEN   the median published price was 17 days old and the oldest 65; Hy-Vee's carry had no age limit.
    - WHERE  202 of 462 Hy-Vee cells came from Omaha #01, retired 2026-08-21; 20 Walmart cells from Bellevue.
    - BUY    the channel gate admitted NO-SIGNAL; Sam's captured no fulfilment at all.
    - ORIGIN 36 cells came from hunter files frozen on 2026-08-16, 12 of whose rows were copied off the board.
  Plus a form defect the name cannot show: Hy-Vee's "That's Smart! Brussels Sprouts" priced the FRESH cell while
  the store's own department on the same row read "Frozen Vegetables".

  THE RULE IS FAIL-CLOSED. A captured row is admitted only when it carries positive proof of all of these, and a
  row that cannot prove one is WITHHELD with a named reason. A withheld cell is a smaller board; a published stale
  or unbuyable price is a wrong number; understating is exactly as wrong as overstating.

    STALE / UNDATED     as_of (the day the price was READ, carried unchanged by every carry lane) older than
                        MaxPublishAgeDays (capture-policy-lib.ps1), or absent.
    WRONG-STORE         the row names a store other than the pinned identity in stores.json.
    UNPROVEN-STORE      a store with a pinned identity (Hy-Vee, Walmart, Fareway) and nothing on the row or its
                        capture file names the store it was read at.
    UNPROVEN-CHANNEL /  a store whose catalogue mixes shelf and ship-only listings (Walmart, Sam's Club) and the
    SHIP-ONLY           row does not prove it is buyable in-store or for pickup at that store.
    SELF-SOURCED        the row came from a file nothing re-captures (hunter-*-regular-*) or its source is our
                        own pricing agent / board.
    WRONG-FORM          the store's own department names a form (frozen, canned) that the commodity's own rule
                        excludes. Evaluated with the COMMODITY'S exclude patterns, so no new vocabulary exists here.

  WHAT IT DOES NOT JUDGE. Ad-flyer rows (kind 'ad'): a flyer carries its own window and Test-AdWindowClosed /
  the per-row ad_to check already retire it. Identity by name: that is match-lib's job.

  SCOPE OF A CLEAN REPORT: unsound. It sees only the fields a capture wrote; a row that states a store or channel
  falsely passes. A refusal is COMPLETE for STALE, UNDATED and SELF-SOURCED (the field IS the defect) and a
  candidate to read for the rest (a legacy row may simply lack the stamp).

  Dot-source it; it declares no parameters (a shared library must not - see capture-policy-lib's header).
  Self-test:  powershell -NoProfile -File grocery\provenance-contract-lib.ps1 -SelfTest
#>
$__pclSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
$script:PclRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# Stores whose catalogue carries ship-only listings beside shelf ones, so a row must PROVE it is on the shelf.
# Every other store's capture surface is its in-store shelf by construction (Hy-Vee/Family Fare/Baker's store APIs,
# Aldi/Fareway In-Store mode, which compare-deals' price-mode gate already enforces per file).
$script:PclChannelStores = @('Walmart', "Sam's Club")
# Form words a store department can state, tested against the commodity's own excludes.
$script:PclFormWords = @('frozen', 'canned')

# The pinned identity per store, read once from stores.json: store_id / retailer_location, plus the retired ids.
function Get-PclPinnedStores([string]$StoresJson = '') {
  if (-not $StoresJson) { $StoresJson = Join-Path $script:PclRoot 'stores.json' }
  $pins = @{}
  $doc = [IO.File]::ReadAllText($StoresJson) | ConvertFrom-Json
  foreach ($s in $doc.stores) {
    $si = $s.store_identity
    if (-not $si) { continue }
    $id = if ($si.store_id) { [string]$si.store_id } elseif ($si.retailer_location) { [string]$si.retailer_location } else { '' }
    if (-not $id) { continue }
    $zip = if ($si.postal_code) { [string]$si.postal_code } elseif ($si.flyer_postal_code) { [string]$si.flyer_postal_code } else { '' }
    $pins[[string]$s.name] = [pscustomobject]@{ id = $id; zip = $zip }
  }
  return $pins
}

# The day the row's price was read. A carry lane keeps as_of; a union store's row may carry none and is dated by
# its capture file (it is never carried, so the file date IS its read date).
function Get-PclReadDate($Row, [string]$FileDate) {
  foreach ($f in @('as_of', 'verified_on', 'captured_at')) {
    if ($Row -and $Row.PSObject.Properties[$f]) {
      $v = [string]$Row.$f
      if ($v -match '^(\d{4}-\d{2}-\d{2})') { return $Matches[1] }
    }
  }
  if ($FileDate -match '^\d{4}-\d{2}-\d{2}$') { return $FileDate }
  return ''
}

# Every store identity the row or its file states: explicit fields first, then the source text.
function Get-PclStatedStores($Row, [string]$FileSource) {
  $ids = New-Object System.Collections.Generic.List[string]
  $texts = New-Object System.Collections.Generic.List[string]
  foreach ($f in @('store_id', 'loc', 'store_location', 'club')) {
    if ($Row -and $Row.PSObject.Properties[$f] -and [string]$Row.$f) { [void]$ids.Add(([string]$Row.$f).Trim()) }
  }
  if ($Row -and $Row.PSObject.Properties['source_ad'] -and [string]$Row.source_ad) { [void]$texts.Add([string]$Row.source_ad) }
  if ($FileSource) { [void]$texts.Add($FileSource) }
  foreach ($t in $texts) {
    foreach ($m in [regex]::Matches($t, '(?i)\bstore(?:Id|\s*id)?\s*[:=#]?\s*(\d{3,7})\b')) { [void]$ids.Add($m.Groups[1].Value) }
  }
  return [pscustomobject]@{ ids = @($ids | Select-Object -Unique); text = (@($texts) -join ' | ') }
}

<#
  Test-CellProvenance: $true/$false plus a named reason.
    -Store          the row's store name as the board spells it
    -Row            the CAPTURE row (the object read from the capture file)
    -Kind           'capture' (everyday shelf/storefront/club rows) or 'ad' (flyer rows: always admitted here)
    -FileDate       the capture file's date (yyyy-MM-dd)
    -SrcFile        the capture file's base name
    -FileSource     the capture file's own source/store statement (e.g. its #tc-store derived `source`)
    -Commodity      the commodity object the row matched (its .exclude patterns decide WRONG-FORM)
    -BoardDate      the board's date; age is judged against it, never the wall clock
    -MaxAgeDays     MaxPublishAgeDays
    -Pins           Get-PclPinnedStores
#>
function Test-CellProvenance {
  param([string]$Store, $Row, [string]$Kind = 'capture', [string]$FileDate = '', [string]$SrcFile = '', [string]$FileSource = '',
        $Commodity = $null, [string]$BoardDate, [int]$MaxAgeDays, [hashtable]$Pins)
  $ok = { param($w) [pscustomobject]@{ ok = $true; why = $w; as_of = $script:__pclAsOf } }
  $no = { param($w, $d) [pscustomobject]@{ ok = $false; why = $w; detail = $d; as_of = $script:__pclAsOf } }
  $script:__pclAsOf = Get-PclReadDate $Row $FileDate
  if ($Kind -eq 'ad') { return (& $ok 'AD-WINDOW') }
  if ($Kind -ne 'capture') { throw "unknown provenance kind: $Kind" }

  # ORIGIN before anything else: a board-derived price is not a read at all, whatever its date says.
  $srcAd = if ($Row -and $Row.PSObject.Properties['source_ad']) { [string]$Row.source_ad } else { '' }
  if ($SrcFile -match '^hunter-' -or $srcAd -match '(?i)recipe hunter pricing agent|ingredient-queue|price-ingredient') {
    return (& $no 'SELF-SOURCED' ("from " + $(if ($SrcFile -match '^hunter-') { $SrcFile } else { "source '$srcAd'" }) + ", which no capture re-reads"))
  }

  # WHEN
  $asOf = $script:__pclAsOf
  if (-not $asOf) { return (& $no 'UNDATED' 'the row states no read date and its file has none') }
  $age = ([datetime]::ParseExact($BoardDate, 'yyyy-MM-dd', $null) - [datetime]::ParseExact($asOf, 'yyyy-MM-dd', $null)).TotalDays
  if ($age -gt $MaxAgeDays) { return (& $no 'STALE' ("read $asOf, " + [int]$age + " days before the $BoardDate board (limit $MaxAgeDays)")) }

  # WHERE
  if ($Pins -and $Pins.ContainsKey($Store)) {
    $pin = $Pins[$Store]
    $st = Get-PclStatedStores $Row $FileSource
    $other = @($st.ids | Where-Object { $_ -and $_ -ne $pin.id })
    if ($other.Count) { return (& $no 'WRONG-STORE' ("read at store " + ($other -join ',') + ", pinned store is " + $pin.id)) }
    # A text that names a DIFFERENT town or postal code than the pinned one is the Bellevue shape: no id at all,
    # only a place. Postal codes are compared, never town names (3153 is an Omaha address too).
    $zips = @([regex]::Matches($st.text, '\b(68\d{3})\b') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $otherZip = @($zips | Where-Object { $pin.zip -and $_ -ne $pin.zip })
    if ($otherZip.Count -and -not (@($st.ids) -contains $pin.id)) { return (& $no 'WRONG-STORE' ("read at postal code " + ($otherZip -join ',') + ", pinned store is " + $pin.id + " (" + $pin.zip + ")")) }
    if (-not (@($st.ids) -contains $pin.id) -and -not ($pin.zip -and (@($zips) -contains $pin.zip))) {
      return (& $no 'UNPROVEN-STORE' ("nothing on the row or its file names the store it was read at (pinned " + $pin.id + ")"))
    }
  }

  # BUYABLE
  if ($script:PclChannelStores -contains $Store) {
    $chan = if ($Row -and $Row.PSObject.Properties['channel']) { [string]$Row.channel } else { '' }
    $ff = if ($Row -and $Row.PSObject.Properties['fulfillment']) { ([string]$Row.fulfillment).ToUpperInvariant() } else { '' }
    if ($chan -eq 'ship-only') { return (& $no 'SHIP-ONLY' 'the capture says this listing is not sold in the store') }
    if ($chan -ne 'in-store') {
      # Walmart's pre-channel field: STORE is a shelf listing (in stock is NOT proven by it, which is why the new
      # `channel` field supersedes it the day the lane writes one). Anything else is ship-only.
      if ($Store -eq 'Walmart' -and $ff -eq 'STORE') { }
      elseif ($ff -and $ff -ne 'STORE') { return (& $no 'SHIP-ONLY' ("fulfillment " + $ff)) }
      else { return (& $no 'UNPROVEN-CHANNEL' 'nothing on the row proves it is sold in the store or for pickup there') }
    }
  }

  # FORM, in the store's own words, judged by the commodity's own excludes
  if ($Commodity -and $Row) {
    $dept = @(foreach ($f in @('store_department', 'store_department_group', 'store_category', 'department', 'aisle')) {
      if ($Row.PSObject.Properties[$f] -and [string]$Row.$f) { [string]$Row.$f } }) -join ' / '
    if ($dept) {
      foreach ($w in $script:PclFormWords) {
        if ($dept -notmatch ('(?i)\b' + $w + '\b')) { continue }
        foreach ($x in @($Commodity.exclude)) {
          if ($x -and ($w -match [string]$x)) { return (& $no 'WRONG-FORM' ("the store files it under '" + $dept + "' and " + [string]$Commodity.id + " excludes '" + $w + "'")) }
        }
      }
    }
  }
  return (& $ok 'PROVEN')
}

if ($__pclSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:pn = 0; $script:pbad = 0
  function _P([string]$label, [bool]$cond, [string]$got) {
    $script:pn++
    if ($cond) { Write-Output ('  ok    ' + $label) } else { $script:pbad++; Write-Output ('  FAIL  ' + $label + '   got: ' + $got) }
  }
  function _R([hashtable]$h) { return [pscustomobject]$h }
  try {
    $pins = Get-PclPinnedStores
    _P 'PREMISE  stores.json pins Hy-Vee 1466, Walmart 5361 and Fareway 531573' ($pins['Hy-Vee'].id -eq '1466' -and $pins['Walmart'].id -eq '5361' -and $pins['Fareway'].id -eq '531573') (($pins.Keys | ForEach-Object { "$_=$($pins[$_].id)" }) -join ',')
    $B = '2026-09-17'; $M = 14
    $sprouts = _R @{ id = 'brussels-sprouts'; exclude = @('\bfrozen\b', 'shaved\s+blend') }
    $frozenSprouts = _R @{ id = 'frozen-brussels-sprouts'; exclude = @('\bfresh\b') }

    # --- WHEN: the bar is MaxPublishAgeDays; at it passes, one day past it fails (I196)
    $at = Test-CellProvenance -Store 'Aldi' -Row (_R @{ as_of = '2026-09-03' }) -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST NOT FIRE  a row read exactly 14 days before the board (the bar) is admitted' ($at.ok) "$($at.why) $($at.detail)"
    $past = Test-CellProvenance -Store 'Aldi' -Row (_R @{ as_of = '2026-09-02' }) -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  a row read 15 days before the board (one day past the bar) is STALE' (-not $past.ok -and $past.why -eq 'STALE') "$($past.why) $($past.detail)"
    $apple = Test-CellProvenance -Store 'Hy-Vee' -Row (_R @{ as_of = '2026-07-15'; source_ad = 'everyday shelf price' }) -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  the founding Hy-Vee apple juice row (as_of 2026-07-15, 64 days) is STALE' (-not $apple.ok -and $apple.why -eq 'STALE') $apple.why
    $undated = Test-CellProvenance -Store 'Aldi' -Row (_R @{ item = 'x' }) -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  a row with no read date and no file date is UNDATED, never admitted' (-not $undated.ok -and $undated.why -eq 'UNDATED') $undated.why
    $fileDated = Test-CellProvenance -Store 'Aldi' -Row (_R @{ item = 'x' }) -FileDate '2026-09-16' -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'CLEAN TWIN  a row with no as_of is dated by its capture file' ($fileDated.ok -and $fileDated.as_of -eq '2026-09-16') "$($fileDated.why) $($fileDated.as_of)"

    # --- WHERE
    $hv1465 = Test-CellProvenance -Store 'Hy-Vee' -Row (_R @{ as_of = '2026-09-10'; source_ad = 'Aisles Online current shelf price (storeId 1465, Omaha #01)' }) -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  a fresh Hy-Vee row read at the retired storeId 1465 is WRONG-STORE' (-not $hv1465.ok -and $hv1465.why -eq 'WRONG-STORE') "$($hv1465.why) $($hv1465.detail)"
    $hv1466 = Test-CellProvenance -Store 'Hy-Vee' -Row (_R @{ as_of = '2026-09-10'; source_ad = 'Aisles Online current shelf price (storeId 1466, Omaha #02)' }) -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST NOT FIRE  a fresh Hy-Vee row read at the pinned 1466 is admitted' ($hv1466.ok) "$($hv1466.why) $($hv1466.detail)"
    $hvStamp = Test-CellProvenance -Store 'Hy-Vee' -Row (_R @{ as_of = '2026-09-10'; store_id = '1466'; source_ad = 'everyday shelf price' }) -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'CLEAN TWIN  a store_id stamp proves the store without any source text' ($hvStamp.ok) "$($hvStamp.why) $($hvStamp.detail)"
    $hvNone = Test-CellProvenance -Store 'Hy-Vee' -Row (_R @{ as_of = '2026-09-10'; source_ad = 'everyday shelf price' }) -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  a Hy-Vee row that names no store at all is UNPROVEN-STORE' (-not $hvNone.ok -and $hvNone.why -eq 'UNPROVEN-STORE') "$($hvNone.why) $($hvNone.detail)"
    $wmBell = Test-CellProvenance -Store 'Walmart' -Row (_R @{ source_ad = 'Walmart Bellevue 68123 shelf price (batch capture)'; fulfillment = 'STORE' }) -FileDate '2026-09-05' -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  the founding Walmart Bellevue 68123 row is WRONG-STORE (by postal code, not town name)' (-not $wmBell.ok -and $wmBell.why -eq 'WRONG-STORE') "$($wmBell.why) $($wmBell.detail)"
    $wmOk = Test-CellProvenance -Store 'Walmart' -Row (_R @{ source_ad = 'everyday shelf price'; fulfillment = 'STORE' }) -FileDate '2026-09-12' -FileSource 'walmart.com store 5361 (68137)' -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST NOT FIRE  a Walmart row whose capture file names store 5361 with fulfillment STORE is admitted' ($wmOk.ok) "$($wmOk.why) $($wmOk.detail)"
    $wmWaived = Test-CellProvenance -Store 'Walmart' -Row (_R @{ source_ad = 'everyday shelf price'; fulfillment = 'STORE' }) -FileDate '2026-09-12' -FileSource 'store NOT RECORDED (-WaiveMissingStoreLine)' -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  a Walmart row from a capture built under -WaiveMissingStoreLine is UNPROVEN-STORE' (-not $wmWaived.ok -and $wmWaived.why -eq 'UNPROVEN-STORE') "$($wmWaived.why) $($wmWaived.detail)"
    $fw = Test-CellProvenance -Store 'Fareway' -Row (_R @{ as_of = '2026-09-12'; loc = '513473' }) -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  a Fareway row stamped with Des Moines 513473 is WRONG-STORE' (-not $fw.ok -and $fw.why -eq 'WRONG-STORE') "$($fw.why) $($fw.detail)"
    $aldi = Test-CellProvenance -Store 'Aldi' -Row (_R @{ as_of = '2026-09-12' }) -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'CLEAN TWIN  Aldi is deliberately not pinned, so no store proof is asked of it' ($aldi.ok) "$($aldi.why) $($aldi.detail)"

    # --- BUYABLE
    $samsOld = Test-CellProvenance -Store "Sam's Club" -Row (_R @{ as_of = '2026-09-17'; item = "Magnolia Sweetened Condensed Milk, 14 oz., 6 pk." }) -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  a Sam''s row that records no channel (every capture before this change) is UNPROVEN-CHANNEL' (-not $samsOld.ok -and $samsOld.why -eq 'UNPROVEN-CHANNEL') "$($samsOld.why) $($samsOld.detail)"
    $samsShip = Test-CellProvenance -Store "Sam's Club" -Row (_R @{ as_of = '2026-09-17'; channel = 'ship-only' }) -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  a Sam''s row the capture marks ship-only is SHIP-ONLY' (-not $samsShip.ok -and $samsShip.why -eq 'SHIP-ONLY') "$($samsShip.why)"
    $samsIn = Test-CellProvenance -Store "Sam's Club" -Row (_R @{ as_of = '2026-09-17'; channel = 'in-store' }) -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST NOT FIRE  a Sam''s row proven in-club is admitted' ($samsIn.ok) "$($samsIn.why) $($samsIn.detail)"
    $wmNoSig = Test-CellProvenance -Store 'Walmart' -Row (_R @{ source_ad = 'everyday shelf price' }) -FileDate '2026-09-12' -FileSource 'store 5361' -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  a Walmart row with no channel and no fulfillment (the NO-SIGNAL admission) is UNPROVEN-CHANNEL' (-not $wmNoSig.ok -and $wmNoSig.why -eq 'UNPROVEN-CHANNEL') "$($wmNoSig.why)"
    $wmFc = Test-CellProvenance -Store 'Walmart' -Row (_R @{ source_ad = 'everyday shelf price'; fulfillment = 'MARKETPLACE' }) -FileDate '2026-09-12' -FileSource 'store 5361' -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  a Walmart Marketplace row is SHIP-ONLY' (-not $wmFc.ok -and $wmFc.why -eq 'SHIP-ONLY') "$($wmFc.why)"
    $wmOos = Test-CellProvenance -Store 'Walmart' -Row (_R @{ source_ad = 'everyday shelf price'; fulfillment = 'STORE'; channel = 'ship-only' }) -FileDate '2026-09-12' -FileSource 'store 5361' -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  a Walmart STORE listing the capture proves out of stock at 5361 (channel ship-only) is SHIP-ONLY: the new field outranks the old one' (-not $wmOos.ok -and $wmOos.why -eq 'SHIP-ONLY') "$($wmOos.why)"

    # --- ORIGIN
    $hunt = Test-CellProvenance -Store 'Fareway' -Row (_R @{ as_of = '2026-09-16'; loc = '531573'; source_ad = 'Recipe Hunter pricing agent (in-store verified, ingredient-queue)' }) -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  the founding $0.77 bell pepper (a Recipe Hunter row) is SELF-SOURCED even when fresh and correctly stamped' (-not $hunt.ok -and $hunt.why -eq 'SELF-SOURCED') "$($hunt.why)"
    $huntFile = Test-CellProvenance -Store 'Baker''s' -Row (_R @{ as_of = '2026-09-16' }) -SrcFile 'hunter-bakers-regular-2026-08-16' -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  any row from a hunter-*-regular file is SELF-SOURCED' (-not $huntFile.ok -and $huntFile.why -eq 'SELF-SOURCED') "$($huntFile.why)"

    # --- FORM
    $hvFrozen = _R @{ as_of = '2026-09-10'; store_id = '1466'; item = "That's Smart! Brussels Sprouts"; store_department = 'Frozen Fruits & Vegetables'; store_category = 'Frozen Vegetables' }
    $wf = Test-CellProvenance -Store 'Hy-Vee' -Row $hvFrozen -Commodity $sprouts -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST FIRE  the founding Hy-Vee frozen sprouts, filed under Frozen Vegetables, cannot price the FRESH brussels-sprouts cell' (-not $wf.ok -and $wf.why -eq 'WRONG-FORM') "$($wf.why) $($wf.detail)"
    $rf = Test-CellProvenance -Store 'Hy-Vee' -Row $hvFrozen -Commodity $frozenSprouts -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'CLEAN TWIN  the same frozen row still prices frozen-brussels-sprouts, whose rule does not exclude frozen' ($rf.ok) "$($rf.why) $($rf.detail)"
    $fresh = Test-CellProvenance -Store 'Hy-Vee' -Row (_R @{ as_of = '2026-09-10'; store_id = '1466'; store_department = 'Produce' }) -Commodity $sprouts -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'MUST NOT FIRE  a fresh sprouts row filed under Produce is admitted' ($fresh.ok) "$($fresh.why) $($fresh.detail)"

    # --- ADS
    $ad = Test-CellProvenance -Store 'Hy-Vee' -Row (_R @{ item = 'x' }) -Kind 'ad' -BoardDate $B -MaxAgeDays $M -Pins $pins
    _P 'CLEAN TWIN  an ad-flyer row is judged by its own window elsewhere, never here' ($ad.ok -and $ad.why -eq 'AD-WINDOW') $ad.why
    $threw = $false
    try { [void](Test-CellProvenance -Store 'Aldi' -Row (_R @{}) -Kind 'bogus' -BoardDate $B -MaxAgeDays $M -Pins $pins) } catch { $threw = $true }
    _P 'MUST FIRE  an unknown kind refuses loudly (a switch on data owes a default that throws)' $threw "threw=$threw"
  } catch {
    _P 'the self-test ran to its end with no unexpected error' $false ($_.Exception.Message + ' (line ' + $_.InvocationInfo.ScriptLineNumber + ')')
  }
  Write-Output ('provenance-contract-lib SELF-TEST {0} ({1} of {2} failed)' -f $(if ($script:pbad) { 'FAIL' } else { 'PASS' }), $script:pbad, $script:pn)
  if ($script:pbad) { exit 1 }
  exit 0
}
