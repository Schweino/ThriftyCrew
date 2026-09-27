function Add-Norm {
  # NAMED PARAMETERS ONLY (2026-09-19, backlog I191). This builds every board row, and it took 16 untyped
  # positional parameters that its call sites padded with '' and $null to reach the slot they wanted: the
  # capture row landed in slot 15 only because somebody counted, and a slip of one position printed a
  # plausible row with a field in the wrong column. One slip had already happened - the Baker's/Fareway/Sam's
  # supplement loop passed the automatic $pid (this PROCESS's id) in the product-id slot from 9c44c3a37, so
  # every one of those rows carried the build's PID as its store product id and Select-FreshestCaptureRows
  # treated all of a store's rows for a commodity as ONE product. PositionalBinding=$false makes a positional
  # call throw, and [CmdletBinding()] makes a misspelt -Name throw instead of landing silently in $args. The
  # -SelfTest block above holds both as a MUST FIRE and the named row as a CLEAN TWIN.
  [CmdletBinding(PositionalBinding = $false)]
  param($Store, $Name, $PriceText, $SizeText, $Regular, $SourceAd, $PriceType = 'sale', $SrcDate = '', $AdFrom = '',
        $AdTo = '', $AdBasis = '', $ProductId = '', $Fulfillment = '', $SrcFile = '', $SrcRow = $null, $SplitFrom = '',
        # THE PROVENANCE CONTRACT'S INPUTS (2026-09-19): the capture row as read ($ProvRow - separate from $SrcRow,
        # which some call sites withhold on purpose), whether it is a CAPTURE (judged) or an AD-flyer row (judged by
        # its own window), and what the capture FILE says about the store it was read at.
        $ProvRow = $null, $ProvKind = 'ad', $FileSource = '',
        # THE TYPE THIS ROW HAD BEFORE A ROLLBACK SPLIT (2026-09-26, PLAN-board-clock W1b). Only the identical-row
        # dedupe after matching reads it - see the note there. '' = the row's own price_type.
        $DedupeType = '')
  # THE FORMAT LAYER, AND THE ONE DROP HERE THAT SAID NOTHING (2026-09-07, backlog E5). A row whose
  # name did not parse vanishes before any business rule runs, so a capture whose name field moved
  # would yield fewer rows and produce no signal at all - "silent by construction". It is still
  # dropped, on the same condition, at the same place: no branch is added, so the engine cannot price
  # differently because of this. It is only no longer invisible.
  #
  # PER STORE, because the total is the wrong grain: three nameless rows across seven stores is feed
  # noise, three from ONE store is that store's capture shape having moved.
  #
  # NULL-SAFE, because a $script: variable does not travel with a lifted function and three scripts
  # lift these ([[compare-deals-lifters-need-functions-not-variables]]).
  if (-not $Name) { $null = Add-TcNamelessRow $Store; return }
  # src_date = the date of the CAPTURE FILE this row came from (not the ad cycle). Only rows loaded from dated
  # per-store capture files carry it; it is how the ranking step below can prefer the freshest capture that
  # covers a commodity instead of letting an older capture's price compete with it.
  # ad_from / ad_to = THE WINDOW THIS PARTICULAR DEAL RUNS IN, carried from the feed that supplied it.
  # Added 2026-08-21 (Brad: "we MUST log ad dates and pricing"). Before this the engine had no per-deal
  # window at all, so build-sale-windows fell back to the ONE store-level window in ad-schedule.json -
  # and Hy-Vee runs THREE flyers at once (Weekly 08-17..08-23, monthly 08-03..08-30, 3 Day Sale
  # 08-21..08-23). All 28 of its sale cells collapsed onto the weekly window, retiring the 216
  # monthly-ad deals seven days early while the ad was still running.
  # BLANK STAYS BLANK: a row whose source states no window must not inherit a neighbour's. That is the
  # borrowed-window bug guard 8 exists for, and it is why this is carried rather than defaulted.
  # AN EXPIRED SALE DOES NOT PRICE THE BOARD, PER ROW (2026-08-21).
  # Test-AdWindowClosed already refuses a whole flyer FILE outside its window, which was the only
  # granularity available while the engine had no per-row dates. It is not enough now: Hy-Vee runs
  # three flyers at once inside ONE ads file, and Baker's per-item promos in one capture legitimately
  # end 7, 14, 28 and 32 days apart. Without this check the dates would be decorative - captured,
  # carried, displayed, and never acted on - which is the shape this whole session keeps finding.
  # Judged against the JUDGE date ($script:JudgeDay = -JudgeDate, default the real date; a pinned regression run
  # passes its frozen date), never the ad set's date, which lags whenever no weekly ad is due (2026-09-26).
  # A row with no ad_to is NOT expired: absent evidence is not evidence, and an undated markdown is
  # handled by its own TTL rather than by being silently dropped here.
  if ($PriceType -eq 'sale' -and $AdTo -match '^\d{4}-\d{2}-\d{2}$' -and $script:JudgeDay) {
    if ([string]$AdTo -lt [string]$script:JudgeDay) { $script:ExpiredSaleRows++; return }
  }
  # fulfillment: the store's own word on whether this row is sold on the shelf. Carried raw ('' when the
  # capture predates the field) so Test-InStore can tell "not in store" from "not stated".
  # src_file: WHICH capture this row came from, carried because "was the field populated in the file this
  # row came from" is a different question from "does this row carry the field", and the second one cannot
  # answer it. A blank inside a capture that fills the field on 99% of its rows is an unattributed row,
  # not a pre-field one. See the channel block in instore-lib.ps1.
  # native_up / native_up_unit: THE STORE'S OWN PER-UNIT NUMBER, parsed once at ingest from the capture row
  # ($srcRow, passed only by the loaders whose rows carry sams_unit_price / wm_unit_price). Carried RAW -
  # value plus the unit the store quoted it in - because the commodity is not known here; the emit resolves
  # it against the commodity's unit. Absent on every other store's rows, which is correct: they publish no
  # unit price and an absent proof must never read as an agreeing one.
  $nup = $null
  if ($SrcRow) { $nup = Get-DisplayedUnitPrice $SrcRow }
  # pu_rounding_pct: THE ERROR BAR ON A SAM'S DERIVED SIZE (2026-09-11, queue 2026-09-10-c8eb72). Sam's prints
  # its unit price rounded to the CENT and build-sams-deals derives any pack size Sam's did not state as
  # linePrice / that rounded number, so the size - and therefore this row's per-unit - carries a relative error
  # of 0.005/unitPrice. Both fields the computation needs are ALREADY on every Sam's row (qty_basis and
  # sams_unit_price), including the carried 2026-09-01 row that holds the bbq-sauce crown, so no capture is
  # rewritten to gain this. Null on every other store's rows, which is correct: nobody else's size is a
  # quotient, and an absent error bar must never read as a measured zero.
  # The RULE is pricing-math-lib's, so the builder and the board compute the same number from the same fields.
  $purp = $null
  if ($SrcRow) { $purp = Get-DerivedRoundingPct ([string]$SrcRow.qty_basis) ([string]$SrcRow.sams_unit_price) }
  # split_from: the WHOLE flyer line this row was cut out of, when Split-TwoProductAdLine cut it (queue
  # 2026-09-10-582032). Carried so audit-match-soundness and the identity table can show provenance, and so
  # Get-UnitPrice can tell a part whose size is its own from a two-size line nobody has split.
  # link / link_source (PLAN-link-rides-with-price L1): the product URL of the row that set this price, so the price
  # and its link are one record. $SrcRow and $ProvRow are both the capture row; a flyer line passes neither.
  $lkRow = if ($SrcRow) { $SrcRow } else { $ProvRow }
  if ($null -eq $script:TcSamsAlnumProven) { $script:TcSamsAlnumProven = [bool](Test-SamsAlnumShapeProven $OutDir).proven }
  $lkUrl = Get-TcRowUrl $Store $lkRow $script:TcSamsAlnumProven
  $lkSrc = Get-TcLinkSource ([string]$lkUrl) ($null -ne $lkRow)
  $deals.Add([pscustomobject]@{ store=$Store; link=[string]$lkUrl; link_source=$lkSrc; name=[string]$Name; price_text=[string]$PriceText; size_text=[string]$SizeText; regular=$Regular; source_ad=$SourceAd; price_type=$PriceType; src_date=[string]$SrcDate; ad_from=[string]$AdFrom; ad_to=[string]$AdTo; ad_basis=[string]$AdBasis; product_id=[string]$ProductId; fulfillment=[string]$Fulfillment; src_file=[string]$SrcFile; native_up=$(if ($nup) { [double]$nup.Value } else { $null }); native_up_unit=$(if ($nup) { [string]$nup.Unit } else { '' }); pu_rounding_pct=$purp; split_from=[string]$SplitFrom; dedupe_type=[string]$DedupeType; prov_row=$ProvRow; prov_kind=[string]$ProvKind; file_source=[string]$FileSource })
}
$ads = Read-JsonFile $AdsFile
# TWO DATES, EACH NAMED FOR WHAT IT IS (2026-09-26, design\PLAN-board-clock-2026-09-26.md).
#   $today = the AD SET this board is for: week_of, and the D in comparison-<D>.json and its siblings. A NAME only.
#   $judge = the date validity is JUDGED at (-JudgeDate, default the real date). Every age and expiry reads it.
# Until 2026-09-26 $today did both jobs, and ads-<D>.json is written only on a day a weekly ad is pulled. With no ad
# due 09-24..09-26 it lagged 3 days, and the board priced 9 cells from windows that had ended 09-23..09-25 (5 of
# them crowned "Cheapest"), counted 90 + 3 days as inside the 90-day window, and admitted 93-day-old union files.
$today = $ads.today
$judge = if ($JudgeDate) { $JudgeDate } else { (Get-Date).ToString('yyyy-MM-dd') }
if ($judge -notmatch '^\d{4}-\d{2}-\d{2}$') { throw ("compare-deals: -JudgeDate must be yyyy-MM-dd, got '" + $judge + "'") }
# Visible to Add-Norm so it can refuse an expired sale row. Script-scoped because Add-Norm is a function and cannot
# see this scope otherwise.
$script:JudgeDay = [string]$judge
$script:ExpiredSaleRows = 0
$script:RollbackSplit = 0      # W1b: marked-down EVERYDAY-file rows with a window, emitted as a sale half
$script:RollbackRevert = 0     # W1b: of those, how many also emitted the store's own was-price as the everyday half
$script:NamelessRows = 0
$script:NamelessRowsByStore = @{}
foreach ($d in $ads.deals) {                                                                # weekly ads = 'sale'
  # ONE FLYER LINE CAN SELL TWO PRODUCTS (2026-09-11, queue 2026-09-10-582032). The split is the SAME
  # function the supplement loop below calls - one copy of the rule, at the ingest seam, before matching
  # ever sees the name. On ads-2026-09-11 it fires ZERO times by measurement: Hy-Vee's two-product shape is
  # "A size, B size, $price" (10 lines, 4 routing, 0 holding a cell), which the strict rule deliberately
  # leaves WHOLE because the loose rule that split it manufactured a wrong-product coffee crown in
  # simulation. Those lines are refused by Get-UnitPrice instead of being priced by an arbitrary one of
  # their two sizes. Routing this loop through the one function is the point: the next flyer that writes
  # "A, size or B, size" here is handled the day it lands rather than the day somebody notices.
  # Brad's ruling Q-adline-two-products (2026-09-22): a line naming two or more products at ONE size is split
  # per product too (Split-AdLineProducts, in Get-AdLineParts with the sized split above).
  $adParts = Get-AdLineParts ([string]$d.item) $d.size
  $adParts = @($adParts)
  $sf = if ($adParts.Count -gt 1) { [string]$d.item } else { '' }
  foreach ($ap in $adParts) {
    $pn = [string]$ap.name
    # the file row's size belongs to a part only when it states that part's own size expression; otherwise
    # the size is cut from the part itself. Unsplit lines keep $d.size byte for byte.
    $pSize = if ($adParts.Count -gt 1) { $ap.size } else { $d.size }
    switch ($d.store) {
      # pull-grocery-ads stamps ad_from/ad_to on EVERY deal now - per FLYER for Hy-Vee (it runs three at
      # once), per ITEM for Aldi (flyerkit gives each product its own), per CIRCULAR for Family Fare.
      # Passing them through is the entire point of having captured them.
      # Aldi also now carries original_price as `regular`, so an Aldi ad row can state what it was cut from.
      'Hy-Vee'      { Add-Norm -Store $d.store -Name $pn -PriceText $pn -SizeText $null -Regular $null -SourceAd $d.source_ad -PriceType 'sale' -AdFrom $d.ad_from -AdTo $d.ad_to -SplitFrom $sf }      # price+size embedded in item text
      'Aldi'        { Add-Norm -Store $d.store -Name $pn -PriceText $d.ad_price -SizeText $pSize -Regular $d.regular -SourceAd $d.source_ad -PriceType 'sale' -AdFrom $d.ad_from -AdTo $d.ad_to -SplitFrom $sf }
      'Family Fare' { Add-Norm -Store $d.store -Name $pn -PriceText $d.ad_price -SizeText $pSize -Regular $d.regular -SourceAd $d.source_ad -PriceType 'sale' -AdFrom $d.ad_from -AdTo $d.ad_to -SplitFrom $sf }
      default       { Add-Norm -Store $d.store -Name $pn -PriceText ($d.ad_price + ' ' + $pn) -SizeText $pSize -Regular $d.regular -SourceAd $d.source_ad -PriceType 'sale' -AdFrom $d.ad_from -AdTo $d.ad_to -SplitFrom $sf }
    }
  }
}
# ad-based extra files (Baker's ad, Sam's, Fareway weekly-ad sales). Each file may declare price_type (Sam's
# warehouse price = everyday); default sale. Fareway's EVERYDAY storefront prices load from out\regular\ above;
# -FarewayFile is only its weekly-ad SALE supplement (vision-read promos the storefront may not show online).
#
# AUTO-DISCOVER when not passed (2026-07-16). These used to be caller-supplied ONLY, while out\regular\ was
# auto-discovered - so running `compare-deals.ps1` bare silently built a board with NO Sam's ad prices (Sam's
# has no out\regular\ file at all: its prices come only from out\sams\sams-deals-*.json). That is exactly what
# happened today: a bare re-run cut Sam's from 201 priced chips to 112 and quietly dropped 125 chips across
# Sam's/Baker's/Hy-Vee/Walmart, and the publish coverage gate did not catch it because 112 > its MinPerStore.
# A store must never disappear because of how the engine was invoked. Explicit args still win.
if (-not $BakersFile)  { $f = Get-ChildItem (Join-Path $OutDir 'bakers\bakers-deals-*.json')   -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1; if ($f) { $BakersFile  = $f.FullName; Write-Warning ("compare-deals: -BakersFile not passed; auto-using "  + $f.Name) } }
if (-not $FarewayFile) { $f = Get-ChildItem (Join-Path $OutDir 'fareway\fareway-deals-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1; if ($f) { $FarewayFile = $f.FullName; Write-Warning ("compare-deals: -FarewayFile not passed; auto-using " + $f.Name) } }

# FAREWAY RUNS TWO ADS AT ONCE (2026-08-09). A weekly Sun-Sat flyer AND a ~4-week monthly one, with
# overlapping windows - on 08-09 the monthly covered 08-03..08-29 while the weekly covered 08-10..08-15.
# Both are real sale prices, and "newest fareway-deals-*.json by name" can only ever see one of them, so the
# monthly ad had NEVER reached a board: every deals file this estate produced read the weekly only. Picking
# the newest is also actively wrong the moment the next weekly is captured early, because that file shadows a
# monthly that is still live for another three weeks.
# Safe to load them all now only because each file self-gates on its own ad_from/ad_to (Test-AdWindowClosed) -
# an out-of-window file refuses itself rather than leaking into the board. Explicit -FarewayFile still wins,
# and the sibling pick-up is skipped entirely when the caller pinned one, so a regression run stays pinned.
# SCOPED TO THE PINNED FILE'S OWN FOLDER, not to $OutDir. A regression harness that pins a fixture pulls in
# only that fixture's siblings and stays hermetic; production pins out\fareway\... and picks up the real ones.
# Pinning one file must never mean silently ignoring a second ad that is live at the same time.
$farewayExtra = @()
if ($FarewayFile -and (Test-Path $FarewayFile)) {
  $fwDir = Split-Path $FarewayFile -Parent
  $pinned = Split-Path $FarewayFile -Leaf
  foreach ($f in (Get-ChildItem (Join-Path $fwDir 'fareway-deals-*.json') -EA SilentlyContinue | Sort-Object Name -Descending)) {
    if ($f.Name -eq $pinned) { continue }
    $farewayExtra += $f.FullName
  }
  if ($farewayExtra.Count) { Write-Warning ("compare-deals: Fareway runs concurrent ad windows; also loading " + $farewayExtra.Count + " sibling deals file(s): " + (($farewayExtra | ForEach-Object { Split-Path $_ -Leaf }) -join ', ') + " (each self-gates on its own window)") }
}

# Sam's is captured in PARTIAL SLICES - the club catalog is CAPTCHA-walled, so each run only gets the categories
# it got through before the wall. "Newest file wins" is right for a store we pull whole every week and WRONG for
# Sam's: the 2026-07-15 Omaha-club capture (428 rows) covers ~118 commodities where the 2026-07-08 national
# capture (263 rows) covered ~251, so taking only the newest cut 153 priced cells off the board with no warning.
# Load EVERY Sam's capture inside the age window instead, and let the ranking step keep - per commodity - only
# the rows from the freshest capture that actually covers it. A blind union would be worse than the bug it fixes:
# "cheapest per store" would let a stale-low price from an old capture beat today's real one.
# An explicit -SamsFile still wins (the regression harness pins one file).
Add-InputUsed -Tracker $inputUsage -Path $BakersFile -Role 'bakers-ad'
Add-InputUsed -Tracker $inputUsage -Path $FarewayFile -Role 'fareway-ad'
$samsFiles = @()
if ($SamsFile) { $samsFiles = @($SamsFile) }
else {
  foreach ($f in (Get-ChildItem (Join-Path $OutDir 'sams\sams-deals-*.json') -EA SilentlyContinue | Sort-Object Name -Descending)) {
    if ($f.BaseName -notmatch '(\d{4}-\d{2}-\d{2})$') { continue }
    $age = [math]::Abs(([datetime]$Matches[1] - [datetime]$judge).TotalDays)
    if ($age -gt $SamsMaxAgeDays) { Write-Warning ("compare-deals: skipping " + $f.Name + " (" + [int]$age + "d old > -SamsMaxAgeDays $SamsMaxAgeDays)"); continue }
    $samsFiles += $f.FullName
  }
  if ($samsFiles.Count) { Write-Warning ("compare-deals: -SamsFile not passed; auto-using " + $samsFiles.Count + " Sam's capture(s): " + (($samsFiles | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')) }
}
# Sam's is the clearest case for the ledger: it unions up to 11 captures at once, so "which of these is
# still doing work" is not answerable by eye at all.
foreach ($sfu in $samsFiles) { Add-InputUsed -Tracker $inputUsage -Path $sfu -Role 'sams-deals' }
# EXPIRED ADS DO NOT PRICE THE BOARD (2026-08-07, Brad's call). A weekly-ad supplement declares its own
# window in ad_from/ad_to, and these rows OVERRIDE the everyday storefront price whenever they are cheaper.
# Nothing retired them when the window closed, so a missed ad pull left a dead sale winning cells forever.
# Measured the day this landed: Fareway's newest ad file covered 2026-07-26..08-01 and its $1.99
# "All-Natural Iowa Pork Chops" was still the LIVE board's crown on 08-07, six days after the sale ended,
# against a real Fareway everyday price near $4.00/lb. 15 recipes were costed off it.
#
# This is deliberately NOT the carry-forward case guards.ps1 protects. A carried EVERYDAY row is old but
# still the store's honest price, and dropping it would be a silent cell drop, which is strictly worse.
# An expired SALE price is not old, it is FALSE - the sale is over and the store will not honour it.
#
# Judged against $judge (-JudgeDate, default the real date; a pinned regression run passes its frozen date), never
# the ad set's date, which lags whenever no weekly ad is due (2026-09-26, design\PLAN-board-clock-2026-09-26.md). A file with no ad_to is never expired: absent evidence is not evidence of expiry,
# and the frozen bakers-deals-2026-07-05 fixture declares no window at all.
foreach ($extra in (@($BakersFile,$FarewayFile) + $farewayExtra + $samsFiles)) {
  if ($extra -and (Test-Path $extra)) {
    $ex = Read-JsonFile $extra
    # A WINDOW HAS TWO ENDS (2026-08-09). The ad_to half retires a sale after it closes; nothing stopped one
    # from going live BEFORE it opened, and a price the store will not honour yet is exactly as false as one
    # it will not honour any more. Found the day Fareway's flyer was downloaded on 08-09 and printed "Prices
    # good August 10-15" - capturing it that morning would have published tomorrow's sale prices today, and
    # ad-schedule.json's own current.from said 08-09, so nothing else would have caught it either.
    $why = Test-AdWindowClosed $ex ([datetime]$judge)
    if ($why) {
      Write-Warning ("compare-deals: SKIPPING " + (Split-Path $extra -Leaf) + " - " + $why + ". " + @($ex.deals).Count + " sale row(s) not priced.")
      continue
    }
    $pt = if ($ex.price_type) { [string]$ex.price_type } else { 'sale' }
    $sd = ''
    if ([IO.Path]::GetFileNameWithoutExtension($extra) -match '(\d{4}-\d{2}-\d{2})$') { $sd = $Matches[1] }
    # A Sam's club capture is a SHELF READ and answers to the provenance contract; the Baker's and Fareway files in
    # this loop are weekly FLYERS, judged by their own window above.
    $extraKind = if ($samsFiles -contains $extra) { 'capture' } else { 'ad' }
    $extraFileSource = if ($extraKind -eq 'capture') { (@([string]$ex.source, [string]$ex.club, [string]$ex.store_label) | Where-Object { $_ }) -join ' | ' } else { '' }
    # A FLYER FILE DECLARES ITS WINDOW AT THE DOCUMENT LEVEL, and Test-AdWindowClosed above has already
    # refused the whole file if today falls outside it. Carry that window down onto each row so a cell
    # can be dated individually - and let a row that states its OWN window win, because Fareway runs a
    # weekly and a monthly ad concurrently whose rows legitimately expire on different days.
    foreach ($d in $ex.deals) {
      $rFrom = if ($d.ad_from) { [string]$d.ad_from } else { [string]$ex.ad_from }
      $rTo   = if ($d.ad_to)   { [string]$d.ad_to }   else { [string]$ex.ad_to }
      # ONE FLYER LINE, TWO PRODUCTS (2026-09-11, queue 2026-09-10-582032). This is where the Baker's
      # vision-read flyer lands, and 45 of its 146 lines sell two different products at one price
      # ("Farmland Bacon, 12-16 oz or Oscar Mayer Beef Franks, 15 oz"). Split BEFORE matching sees the name,
      # so each product routes on its own words and divides by its own size; the whole line used to route on
      # whichever product's words first-match-wins and divide by whichever size the transcriber wrote.
      # Split-TwoProductAdLine returns ONE element for every other line, so those are emitted exactly as
      # before.
      $adParts = Get-AdLineParts ([string]$d.item) $d.size   # + one row per named product (Q-adline-two-products)
      $adParts = @($adParts)
      $sf = if ($adParts.Count -gt 1) { [string]$d.item } else { '' }
      foreach ($ap in $adParts) {
        $pn = [string]$ap.name
        $pSize = if ($adParts.Count -gt 1) { $ap.size } else { $d.size }
        # THE STORE'S PRODUCT ID NAMES ONE PRODUCT, AND A SPLIT LINE HAS TWO. Handing both parts the same id
        # would make them the same product to Select-FreshestCaptureRows' supersession, which would let one
        # part evict the other. A part of a split line therefore carries NO id - it is name-keyed, exactly as
        # every ad row without an id already is. Unsplit rows keep theirs.
        # NOT $pid: that is a READ-ONLY automatic variable in PowerShell and assigning it throws
        # mid-ingest, which is how this line announced itself on its first run. READING it does not throw,
        # which is the half that bit: the rename reached this assignment but not the call below, so from
        # 9c44c3a37 to 2026-09-19 the call passed $pid - the build process's id - as every one of these rows'
        # product id, and every Sam's and Fareway ad row for a commodity read as ONE product (backlog I191).
        $partProdId = if ($adParts.Count -gt 1) { '' } else { (Get-RowProductId $d) }
        # A ROLLBACK IS A SALE AND THE PRICE IT REVERTS TO (2026-09-26, design\PLAN-board-clock-2026-09-26.md W1b, Brad's
        # D2). build-sams-deals writes a Sam's markdown into this EVERYDAY file with marked_down=true, the store's own
        # strikethrough in base_price, and the 30-day TTL from first detection in ad_from/ad_to (Brad's rule of
        # 2026-08-21). Typed everyday it could never expire - Add-Norm retires only 'sale' rows - so on 2026-09-26 seven
        # Sam's cells priced the board from windows that ended 09-23..09-25, five of them crowned. It is now the same
        # two rows the out\regular path emits ("AND THE PRICE IT REVERTS TO"): the cut price as a 'sale' with its window,
        # so it retires the day the window ends, and the was-price as 'everyday', so the cell falls back to the store's
        # own regular price, read in the same capture, with no gap. A row with no window or no was-price is unchanged.
        $rowPt = $pt
        $revertTo = $null
        if ($pt -eq 'everyday' -and $adParts.Count -eq 1 -and $d.PSObject.Properties['marked_down'] -and $d.marked_down -eq $true -and [string]$rTo -match '^\d{4}-\d{2}-\d{2}$') {
          $rowPt = 'sale'
          $cutV = 0.0; [void][double]::TryParse(((([string]$d.ad_price) -replace '[^0-9.]', '')), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$cutV)
          $wasV = 0.0; if ($d.PSObject.Properties['base_price'] -and $null -ne $d.base_price) { [void][double]::TryParse(([string]$d.base_price), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$wasV) }
          if ($wasV -gt $cutV -and $cutV -gt 0) { $revertTo = $wasV }
          $script:RollbackSplit++
        }
        # -SrcRow: the capture row itself, so Add-Norm can read the store's own published unit price off it
        # (out\sams\sams-deals-*.json carries sams_unit_price on every row). Passed, never re-parsed here. THE CUT HALF
        # ONLY: that unit price describes what the store charges today, and pairing it with the was-price below would
        # manufacture a disagreement out of a discount.
        $rowBasis = if ($rowPt -ne $pt) { 'ttl' } else { '' }
        Add-Norm -Store $d.store -Name $pn -PriceText $d.ad_price -SizeText $pSize -Regular $d.regular -SourceAd $d.source_ad -PriceType $rowPt -SrcDate $sd -AdFrom $rFrom -AdTo $rTo -AdBasis $rowBasis -ProductId $partProdId -SrcRow $d -SplitFrom $sf -ProvRow $d -ProvKind $extraKind -FileSource $extraFileSource -DedupeType $pt
        if ($null -ne $revertTo) {
          Add-Norm -Store $d.store -Name $pn -PriceText ('$' + $revertTo.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)) -SizeText $pSize -Regular $null -SourceAd $d.source_ad -PriceType 'everyday' -SrcDate $sd -ProductId $partProdId -SplitFrom $sf -ProvRow $d -ProvKind $extraKind -FileSource $extraFileSource
          $script:RollbackRevert++
        }
      }
    }
  }
}
# supplemental agent-authored deals: out\extra-deals-<date>.json (newest). This is how a Hy-Vee/Aldi BOGO gets
# PRICED - the ad feed carries no regular (Flipp returns it empty), so the Wednesday agent looks the item's
# regular shelf price up in Aisles Online and writes it here as {store,item,ad_price:"buy one get one free",
# regular,size}. Same shape as the Baker's file; default price_type 'sale'.
# GUARD: only load an extra file dated within ~7 days of the ads week - "newest" is NOT "current": a leftover
# BOGO file from a prior week would otherwise be re-priced as a live sale forever.
$exDir = if ($ExtraDir) { $ExtraDir } else { $OutDir }   # -ExtraDir: pinnable for the regression harness
$extraF = Get-ChildItem (Join-Path $exDir 'extra-deals-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$exDate = ''
if ($extraF -and $extraF.BaseName -match '(\d{4}-\d{2}-\d{2})$') { $exDate = $Matches[1]; try { if ([math]::Abs(([datetime]$exDate - [datetime]$judge).TotalDays) -gt 7) { $extraF = $null } } catch {} }
if ($extraF) {
  $ex = Read-JsonFile $extraF.FullName
  $pt = if ($ex.price_type) { [string]$ex.price_type } else { 'sale' }

  # A DISCOUNT WE CANNOT DATE IS A DISCOUNT WE CANNOT PUBLISH.
  # Two very different kinds of row live in this file:
  #   * BOGO/multibuy pricing tied to the CURRENT weekly ad. The ad feed carries no regular price, so the
  #     Wednesday agent looks one up and writes it here. Those belong to an ad cycle with a known window and
  #     stay valid for the ad week - that is what the 7-day gate above is for.
  #   * "Aisles Online markdown" snapshots: a cut price an agent happened to SEE on some day. These belong to
  #     no ad cycle, carry no end date, and move constantly.
  # We were replaying the second kind as a live sale for a full week. On 2026-07-14 the board published Hy-Vee
  # sirloin at $6.99/lb off a 2026-07-12 markdown; the store's real price that day was $11.99/lb. FIFTY-ONE
  # cells were being served this way. Worse, build-deals-page stamped them "Sale thru Jul 19" - a date
  # borrowed from the store's ad cycle, which these rows have nothing to do with - so an unverifiable
  # two-day-old snapshot wore the costume of a dated, ad-backed sale. And because the cell is typed `sale`,
  # every price audit SKIPS it by design (a sale is supposed to differ from its product page). The whole class
  # was structurally invisible: it could not be caught by any check we had.
  # Rule: a row claiming a discount, with no end date, is honoured only on the day it was captured.
  $todayReal = (Get-Date -Format 'yyyy-MM-dd')
  $staleDiscount = 0
  foreach ($d in @($ex.deals)) {
    $ap = 0.0; $rg = 0.0
    [void][double]::TryParse((([string]$d.ad_price) -replace '[^0-9.]',''), [ref]$ap)
    [void][double]::TryParse((([string]$d.regular)  -replace '[^0-9.]',''), [ref]$rg)
    $claimsDiscount = ($ap -gt 0 -and $rg -gt 0 -and $ap -lt $rg)
    $dated = [bool]$d.sale_end
    if ($claimsDiscount -and (-not $dated) -and ($exDate -ne $todayReal)) { $staleDiscount++; continue }
    Add-Norm -Store $d.store -Name $d.item -PriceText $d.ad_price -SizeText $d.size -Regular $d.regular -SourceAd $d.source_ad -PriceType $pt -ProductId (Get-RowProductId $d) -SrcRow $d
  }
  if ($staleDiscount -gt 0) {
    Write-Warning ("extra-deals: skipped $staleDiscount undated discount row(s) from $exDate (captured before today, no end date - cannot be shown as a live sale). The board falls back to each store's everyday shelf price, which IS verified against its product link.")
  }
}
