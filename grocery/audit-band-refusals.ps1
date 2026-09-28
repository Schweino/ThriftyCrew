<#
  audit-band-refusals.ps1 - EVERY ROW A PRICE BAND REFUSES MUST BE EXPLAINED AS A BASIS ERROR.
  HOLD SCOPE: board - advisory: it pages and never holds the board (a refusal already kept the row off it)

  Brad, 2026-09-22, on moving every commodity to derived bands: "We need to fix it now, properly, and to make sure we
  are future proof so this doesn't happen again. I dont care how long it takes."

  WHY. A price band has ONE job: refuse a price that is off by a basis error (a pack price read per piece, ounces read
  as pounds, a dropped decimal). On 2026-09-22 the typed band floors turned out to be doing a SECOND, invisible job:
  keeping wrong products off the board (Clancy's Himalayan Pink Salt POPCORN as salt, a jalapeno HUMMUS as jalapenos,
  a butter SEASONING as butter, a smoked-SALMON bowl as cooked quinoa). A band that hides a wrong product is a second,
  invisible copy of the identity rules (gap F1 of design/RCA-holistic-2026-09-22.md), and it fails open the day the
  band moves - which is exactly what switching to derived bands did. The wrong products were fixed at identity
  (commodity excludes); this check keeps the class closed.

  THE RULE. For every row the engine's flagged-<date>.json records as refused by a band (band_ref present), ratio
  r = per-unit / band reference. The refusal is EXPLAINED when the row itself carries the evidence of a basis error:
    - a pack or count N stated in its name or size (N pk, N ct, N count, pack of N, N-pack) with r*N or r/N within
      $BasisTol of 1 (a pack price read per piece, or a piece price read per pack);
    - r or 1/r within 10% of a unit conversion THE COMMODITY'S UNIT can produce: 16 (oz/lb), 128 and 32 (fl oz against a
      gallon or quart), 12 (each/dozen), 100 (cents/dollars), 1000 (g/kg). By unit, because the founding popcorn row sits at
      11.6x salt's reference, and a dozen means nothing on an ounce commodity;
    - r or 1/r of at least 50 (an order-of-magnitude-and-more parse error no real product explains).
  Anything else is UNEXPLAINED: the identity rules matched the row to the commodity, and its price is merely unusual,
  so it is either a wrong product the band is hiding (fix at identity: an exclude, per Brad's shape ruling) or a real
  bargain or premium the band is censoring (fix the band's derivation, never its number). Either way it PAGES, naming
  the row, with the resolver lane:grocery/resolve-match-worklist.ps1 (2026-09-22, plan-2026-09-22-9 b96f21: the backlog is the matching worklist's kind 'band'; a key is decided there one at a time, and a wrong product becomes an exclude through apply-coverage-batch -FromWorklist, every MOVED and DROPPED line reviewed, then audit-match-soundness -Accept).
  $BasisTol = 0.25 and 50 are FIRST PLAUSIBLE NUMBERS, nothing else tried.

  A RATCHET, not a gate red on day one: the unexplained rows on the first measured board are the backlog
  (band-refusals-backlog.json, keyed by row, may only shrink; see the note above Get-TcRefusalKey). Exit 0 = no
  unexplained row outside the backlog first seen today, 2 = at least one such row (each printed by name; since 2026-09-25 a
  row pages on its first day only and then waits on the worklist via out/band-refusals-open.json; since 2026-09-28 a row
  priced at or above its own store's standing cell on the same-date comparison board is SHADOWED and pages only on the first
  run it is not, because until then it cannot move the board), 3 = BLIND (no flagged file, none
  carrying band_ref, or no backlog recorded). What it does when the producer STOPS: no flagged file, or one built with
  no derived bands, is exit 3 and pages as could-not-evaluate, never as clean.
  SCOPE OF A CLEAN REPORT: UNSOUND - a wrong product whose price happens to reproduce a unit conversion is read as a
  basis error. A finding is a candidate for a person or the matching lane, not a verdict.

  Usage: .\audit-band-refusals.ps1 [-OutDir <dir>] [-Date yyyy-MM-dd] | -SelfTest
#>
# The self-test is pure in-memory fixtures; it loads derived-band-lib.ps1.
# gate-inputs: grocery\derived-band-lib.ps1
[CmdletBinding()]
param([string]$OutDir = '', [string]$Date = '', [string]$BacklogFile = '', [string]$OpenFile = '', [string]$VerdictFile = '', [switch]$Accept, [switch]$Tighten, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repo = Split-Path $root -Parent
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

# THE MARK IS A BACKLOG OF NAMED ROWS, not a bare count (measured 2026-09-22: 1,465 band-refused rows on the first all-derived
# board, 221 explained as basis errors and 1,244 not, almost all wrong products refused on the DEAR side - apple rice cakes and
# smoked gouda as apples, fully cooked bacon as bacon). A count ratchet at 1,244 would page on ordinary capture churn and
# mail all of them. So the 1,244 are recorded by key (id|store|name) in grocery\band-refusals-backlog.json: they are the
# matching lane's worklist, and a run PAGES only on an unexplained row that is NOT in the backlog, naming it. The backlog may
# only SHRINK: -Tighten drops keys that no longer occur, -Accept records the current set (the founding run, or a reviewed
# reset), and a plain run never writes it (.claude/rules/ops-and-gates.md, a ratchet's mark).
if (-not $BacklogFile) { $BacklogFile = Join-Path $root 'band-refusals-backlog.json' }
function Get-TcRefusalKey($Row) { return (([string]$Row.id) + '|' + ([string]$Row.store) + '|' + ([string]$Row.name)) }
function Get-TcNewRefusals($Unexplained, [hashtable]$Backlog) {
  $new = New-Object System.Collections.ArrayList
  foreach ($u in @($Unexplained)) { if ($null -ne $u -and -not $Backlog.ContainsKey((Get-TcRefusalKey $u))) { [void]$new.Add($u) } }
  return ,($new.ToArray())
}
# A NEW ROW PAGES ONCE, ON ITS FIRST DAY, AND THEN WAITS ON THE WORKLIST (2026-09-25, plan-2026-09-25-7, queue 2026-09-23-57b66b).
# Until this, a row outside the founding backlog paged EVERY run until someone ran -Accept: the backlog grows only by a
# reviewed reset, and the matching worklist read only the backlog, so a new row was on no docket at all and -Decide could
# not silence it. Measured on flagged-2026-09-23 (built 2026-09-25 08:06): 38 NEW rows, the same rows paged on 2026-09-23,
# 09-24 (twice) and 09-25. The other matching detectors page this way since plan-2026-09-22-9 (Get-MatchPageRows).
# The open set is written to out/band-refusals-open.json with first_seen per key; resolve-match-worklist reads it as kind
# 'band' beside the backlog, and a key with a match-verdicts.json verdict ('band|' + key) leaves the open set for good.
function Get-TcBandOpenRows($Rows, [hashtable]$Prev, [hashtable]$Verdicts, [string]$Today) {
  $out = New-Object System.Collections.ArrayList
  foreach ($u in @($Rows)) {
    if ($null -eq $u) { continue }
    $k = Get-TcRefusalKey $u
    if ($Verdicts.ContainsKey('band|' + $k)) { continue }
    $fs = if ($Prev.ContainsKey($k) -and [string]$Prev[$k]) { [string]$Prev[$k] } else { $Today }
    [void]$out.Add([pscustomobject]@{ key = $k; first_seen = $fs; new = ($fs -eq $Today); row = $u })
  }
  return ,($out.ToArray())
}
# A REFUSAL THAT CANNOT MOVE A CELL DOES NOT PAGE (2026-09-28, queue 2026-09-26-7ed369, a RETURN of 2026-09-23-57b66b).
# A store's cell is its cheapest admitted row, so a refused row priced AT or ABOVE that store's standing cell for the same
# commodity and unit can never change the published price, whether it is a wrong product (the band did its job) or a real
# premium price. Measured on the main open set 2026-09-28 against comparison-2026-09-28: 197 open rows, 177 SHADOWED like
# that, 3 cheaper than their cell, 17 with no cell; of today's 51 first-day rows 45 were shadowed, and the type paged on
# every day 09-23 to 09-28. A shadowed row still counts, still sits in the open set and on the worklist; it pages the
# first run it is NOT shadowed (its cell went, or got dearer), once, recorded as paged_on. No board, or a unit that does
# not line up, is never shadowed: that fails toward paging.
function Get-TcBoardCells($Board) {
  $cells = @{}
  if ($null -eq $Board) { return $cells }
  foreach ($e in @($Board.comparison)) {
    if ($null -eq $e) { continue }
    foreach ($s in @($e.stores)) { if ($null -ne $s -and $null -ne $s.per_unit) { $cells[([string]$e.id) + '|' + ([string]$s.store)] = [pscustomobject]@{ per_unit = [double]$s.per_unit; unit = [string]$s.unit; commodity_unit = [string]$e.unit } } }
  }
  return $cells
}
function Get-TcShadowingCell($Row, [hashtable]$Cells) {
  # The standing cell that makes this refused row unable to move the board, or $null when it could move it.
  $k = ([string]$Row.id) + '|' + ([string]$Row.store)
  if (-not $Cells.ContainsKey($k)) { return $null }
  $c = $Cells[$k]
  if ($c.unit -and $c.commodity_unit -and $c.unit -ne $c.commodity_unit) { return $null }
  if ($Row.PSObject.Properties['unit'] -and [string]$Row.unit -and [string]$Row.unit -ne $c.unit) { return $null }
  if ($null -eq $Row.unit_price) { return $null }
  if ([double]$Row.unit_price -ge $c.per_unit) { return $c }
  return $null
}
function Set-TcBandPageState($Open, [hashtable]$PrevPaged, [hashtable]$Cells, [string]$Today) {
  # Adds shadowed_by, paged_on and page to each open row. A key pages once: on the first run it is open and not shadowed.
  # An open row from before this rule (no paged_on field, first_seen before today) paged on its first day and stays paged.
  foreach ($o in @($Open)) {
    if ($null -eq $o) { continue }
    $sh = Get-TcShadowingCell $o.row $Cells
    $prior = if ($PrevPaged.ContainsKey($o.key)) { [string]$PrevPaged[$o.key] } elseif (-not $o.new) { [string]$o.first_seen } else { '' }
    $pg = (-not $prior) -and ($null -eq $sh)
    $o | Add-Member -NotePropertyName shadowed_by -NotePropertyValue $(if ($sh) { $sh.per_unit } else { $null }) -Force
    $o | Add-Member -NotePropertyName paged_on -NotePropertyValue $(if ($pg) { $Today } else { $prior }) -Force
    $o | Add-Member -NotePropertyName page -NotePropertyValue $pg -Force
  }
  return ,(@($Open))
}
$BasisTol = 0.25
# Unit conversions a basis error can produce, BY THE COMMODITY'S UNIT: a 12x ratio on an ounce commodity is not a dozen.
$script:TcConversionsByUnit = @{ oz = @(16.0, 100.0, 1000.0); lb = @(16.0, 100.0, 1000.0); floz = @(128.0, 32.0, 16.0, 100.0, 1000.0); gallon = @(128.0, 32.0, 100.0); each = @(12.0, 100.0); dozen = @(12.0, 100.0) }
$script:TcConversionTol = 0.1   # a conversion is exact, so it is judged tighter than a pack count; first plausible number

function Get-TcRowCounts([string]$Text) {
  $out = New-Object System.Collections.ArrayList
  foreach ($m in [regex]::Matches(([string]$Text).ToLower(), '(?:(\d+)\s*-?\s*(?:pk|pack|packs|ct|count|ea|each|pc|pcs|pieces?|bags?|cans?|bottles?)\b|pack\s+of\s+(\d+)|\((\d+)\s*pack\))')) {
    foreach ($gi in 1..3) { if ($m.Groups[$gi].Success) { $v = [double]$m.Groups[$gi].Value; if ($v -gt 1 -and -not ($out -contains $v)) { [void]$out.Add($v) } } }
  }
  return ,($out.ToArray())
}

function Test-TcNear([double]$A, [double]$B, [double]$Tol) { if ($B -le 0) { return $false }; return ([math]::Abs(($A / $B) - 1.0) -le $Tol) }

function Get-TcRefusalExplanation($Row, [double]$Tol = 0.25) {
  # '' when UNEXPLAINED, else the basis error that explains it.
  $ref = [double]$Row.band_ref; $pu = [double]$Row.unit_price
  if ($ref -le 0 -or $pu -le 0) { return 'no reference' }
  $r = $pu / $ref; $inv = $ref / $pu
  if ($r -ge 50 -or $inv -ge 50) { return ('order of magnitude (x' + ('{0:0.#}' -f [math]::Max($r, $inv)) + ')') }
  foreach ($n in (Get-TcRowCounts ([string]$Row.name + ' ' + [string]$Row.size_text))) {
    if ((Test-TcNear $r $n $Tol) -or (Test-TcNear $inv $n $Tol)) { return ('pack count ' + $n) }
  }
  $u = if ($Row.PSObject.Properties['unit']) { [string]$Row.unit } else { '' }
  $convs = if ($script:TcConversionsByUnit.ContainsKey($u)) { $script:TcConversionsByUnit[$u] } else { @(100.0, 1000.0) }
  foreach ($k in $convs) { if ((Test-TcNear $r $k $script:TcConversionTol) -or (Test-TcNear $inv $k $script:TcConversionTol)) { return ('unit conversion x' + $k) } }
  return ''
}

function Invoke-TcBandRefusalAudit($Rows) {
  $un = New-Object System.Collections.ArrayList; $ex = 0; $n = 0
  foreach ($r in @($Rows)) {
    if ($null -eq $r -or -not $r.PSObject.Properties['band_ref'] -or $null -eq $r.band_ref) { continue }
    $n++
    $why = Get-TcRefusalExplanation $r $BasisTol
    if ($why) { $ex++ } else { [void]$un.Add($r) }
  }
  return [pscustomobject]@{ examined = $n; explained = $ex; unexplained = $un.ToArray() }
}

if ($SelfTest) {
  $bad = 0; $cases = 0
  function Bc([string]$l, [bool]$ok) { $script:cases++; if ($ok) { Write-Output ('ok    ' + $l) } else { Write-Output ('FAIL  ' + $l); $script:bad++ } }
  # frozen from comparison-2026-09-22's first all-derived dry run
  $popcorn = [pscustomobject]@{ id = 'salt'; store = 'Aldi'; unit = 'oz'; name = 'Clancy S Coconut Oil Himalayan Pink Salt Popcorn 4.6 OZ'; unit_price = 0.4326; band_ref = 0.0373; size_text = '4.6 OZ' }
  Bc 'MUST FIRE  the pink-salt popcorn refused only by the band (0.4326 against salt''s 0.0373, no pack or unit story) is UNEXPLAINED' ((Get-TcRefusalExplanation $popcorn) -eq '')
  $chk = [pscustomobject]@{ id = 'canned-chicken'; store = 'Walmart'; name = '(8 pack) Great Value Chunk Chicken Breast with Rib Meat in Water, 12.5 oz Can'; unit_price = 0.0275; band_ref = 0.2273; size_text = '12.5 oz' }
  Bc 'MUST NOT FIRE  an 8-pack price read per can (0.0275 against 0.2273, x8.3) is a basis error the band exists to refuse' ((Get-TcRefusalExplanation $chk) -like 'pack count 8')
  $oz = [pscustomobject]@{ id = 'ground-beef'; store = "Baker's"; unit = 'lb'; name = 'Kroger 80/20 Ground Beef'; unit_price = 0.3125; band_ref = 5.0; size_text = 'lb' }
  Bc 'MUST NOT FIRE  a per-ounce price read as per-pound (x16) is a unit-conversion basis error' ((Get-TcRefusalExplanation $oz) -like 'unit conversion x16')
  $dec = [pscustomobject]@{ id = 'grits'; store = 'Walmart'; name = 'Quaker Old Fashioned Grits 24 oz'; unit_price = 0.0023; band_ref = 0.135; size_text = '24 oz' }
  Bc 'MUST NOT FIRE  the 2026-07-27 grits decimal-drop (x58) is an order-of-magnitude basis error' ((Get-TcRefusalExplanation $dec) -like 'order of magnitude*')
  $bulk = [pscustomobject]@{ id = 'bay-leaves'; store = "Sam's Club"; name = "Member's Mark Whole Bay Leaves, 2 oz."; unit_price = 4.27; band_ref = 25.1667; size_text = '2 oz' }
  Bc 'MUST FIRE  a real bulk price that a band DID refuse (bay leaves 4.27 against a retail reference of 25.17, no pack or unit story) is UNEXPLAINED and pages: that is the loop that moves the warehouse allowance' ((Get-TcRefusalExplanation $bulk) -eq '')
  # CLEAN TWIN over the band itself: the same real Sam's row, with the retail store numbers frozen from the derived-arm
  # board of 2026-09-22, is ADMITTED by the warehouse floor, so on the live board it never reaches this audit at all.
  . (Join-Path $root 'derived-band-lib.ps1')
  $bayRows = @(@('R1', 7.9733), @('R2', 25.1667), @('R3', 31.9333), @("Sam's Club", 4.27)) | ForEach-Object { [pscustomobject]@{ id = 'bay-leaves'; store = $_[0]; per_unit = $_[1] } }
  $bayBand = (Get-TcDerivedBands -Rows $bayRows -Groups @{ "Sam's Club" = 'warehouse' })['bay-leaves']
  Bc 'CLEAN TWIN  the real Sam''s bulk bay leaves (4.27/oz) are ADMITTED by their derived band''s warehouse floor' (Test-TcInBand $bayBand 4.27 'warehouse')
  Bc 'BAR  a pack count exactly AT the tolerance (r = 8 x 1.25 = 10 against an 8-pack) is explained' ((Get-TcRefusalExplanation ([pscustomobject]@{ name = 'x 8 pack'; unit_price = 10.0; band_ref = 1.0; size_text = '' })) -like 'pack count 8')
  Bc 'BAR  one step past it (r = 10.25 against an 8-pack) is not' ((Get-TcRefusalExplanation ([pscustomobject]@{ name = 'x 8 pack'; unit_price = 10.25; band_ref = 1.0; size_text = '' })) -eq '')
  $a = Invoke-TcBandRefusalAudit @($popcorn, $chk, $bulk, [pscustomobject]@{ id = 'x'; unit_price = 1; band = '1-2' })
  Bc 'MECHANISM  a flagged row with no band_ref (a typed band, or another refusal) is not examined' ($a.examined -eq 3 -and @($a.unexplained).Count -eq 2)
  $bl = @{ (Get-TcRefusalKey $bulk) = $true }
  $nw = Get-TcNewRefusals @($popcorn, $bulk) $bl
  Bc 'MUST FIRE  an unexplained row NOT in the backlog (the popcorn) is NEW and pages by name' (@($nw).Count -eq 1 -and $nw[0].name -eq $popcorn.name)
  Bc 'MUST NOT FIRE  an unexplained row already in the backlog (the bay leaves) is the worklist, not a new page' (-not (@($nw) | Where-Object { $_.name -eq $bulk.name }))
  # frozen from the 2026-09-23 page (queue 2026-09-23-57b66b), which re-paged the same rows on 09-24 twice and 09-25
  $juice = [pscustomobject]@{ id = 'apple-juice'; store = "Baker's"; name = 'Evolution Fresh Cold Pressed Organic Apple Juice - 50 Fl Oz'; unit_price = 0.1998; band_ref = 0.0387; size_text = '50 fl oz' }
  $jk = Get-TcRefusalKey $juice
  $o1 = Get-TcBandOpenRows @($juice) @{} @{} '2026-09-23'
  Bc 'MUST FIRE  a new unexplained row with no open record (the Evolution Fresh juice on 2026-09-23) is first seen today and pages' (@($o1).Count -eq 1 -and $o1[0].new -and $o1[0].first_seen -eq '2026-09-23')
  $o2 = Get-TcBandOpenRows @($juice) @{ $jk = '2026-09-23' } @{} '2026-09-24'
  Bc 'MUST NOT FIRE  the same row the next day (first seen 2026-09-23) does not page again: it waits on the worklist' (@($o2).Count -eq 1 -and -not $o2[0].new)
  Bc 'CLEAN TWIN  the next day''s open row still carries its first_seen and its row, so the worklist and the OPEN line can name it' ($o2[0].first_seen -eq '2026-09-23' -and $o2[0].row.name -eq $juice.name)
  $o3 = Get-TcBandOpenRows @($juice, $popcorn) @{} @{ ('band|' + $jk) = $true } '2026-09-25'
  Bc 'MUST NOT FIRE  a key decided in match-verdicts.json (band|id|store|name) leaves the open set; an undecided sibling stays and pages' (@($o3).Count -eq 1 -and $o3[0].row.name -eq $popcorn.name -and $o3[0].new)
  # A REFUSAL THAT CANNOT MOVE A CELL DOES NOT PAGE (queue 2026-09-26-7ed369). Rows and cells frozen from the 7ed369 page and
  # from comparison-2026-09-28 / band-refusals-open.json on 2026-09-28.
  $fxBoard = [pscustomobject]@{ comparison = @(
      [pscustomobject]@{ id = 'apple-cider-vinegar'; unit = 'floz'; stores = @([pscustomobject]@{ store = "Baker's"; per_unit = 0.0546; unit = 'floz' }) },
      [pscustomobject]@{ id = 'breakfast-sausage'; unit = 'oz'; stores = @([pscustomobject]@{ store = 'Fareway'; per_unit = 5.32; unit = 'oz' }) },
      [pscustomobject]@{ id = 'eggs'; unit = 'dozen'; stores = @([pscustomobject]@{ store = 'Hy-Vee'; per_unit = 1.0; unit = 'each' }) }) }
  $fxCells = Get-TcBoardCells $fxBoard
  Bc 'MECHANISM  Get-TcBoardCells keys each board cell id|store with its per_unit from comparison[].stores[]' ($fxCells.Count -eq 3 -and $fxCells["apple-cider-vinegar|Baker's"].per_unit -eq 0.0546)
  $bragg = [pscustomobject]@{ id = 'apple-cider-vinegar'; store = "Baker's"; name = 'Bragg Organic Apple Cider Vinegar with the Mother'; unit_price = 0.3119; band_ref = 0.0546 }
  $saus = [pscustomobject]@{ id = 'breakfast-sausage'; store = 'Fareway'; name = 'Johnsonville Cooked Original Breakfast Pork Sausage Links - 20oz package'; unit_price = 0.5225; band_ref = 2.88 }
  $cat = [pscustomobject]@{ id = 'cat-food'; store = 'Hy-Vee'; name = 'Sheba cat food, 2.6 or 2.64 oz., 10/ $10.00'; unit_price = 6.1538; band_ref = 1.13225 }
  $egg = [pscustomobject]@{ id = 'eggs'; store = 'Hy-Vee'; name = 'Deli egg protein sliders, 3 ct.'; unit_price = 3.96; band_ref = 1.9 }
  $sp = Set-TcBandPageState (Get-TcBandOpenRows @($bragg, $saus, $cat, $egg) @{} @{} '2026-09-28') @{} $fxCells '2026-09-28'
  $spBy = @{}; foreach ($o in $sp) { $spBy[$o.row.id] = $o }
  Bc 'MUST NOT FIRE  the 7ed369 Bragg ACV at Baker''s (0.3119, dearer than Baker''s own standing cell 0.0546) is SHADOWED: it cannot move the board, so it does not page' ((-not $spBy['apple-cider-vinegar'].page) -and $spBy['apple-cider-vinegar'].shadowed_by -eq 0.0546)
  Bc 'CLEAN TWIN  the shadowed Bragg row stays in the open set, first seen today, never paged (paged_on empty), so the worklist still carries it' (@($sp).Count -eq 4 -and $spBy['apple-cider-vinegar'].new -and $spBy['apple-cider-vinegar'].paged_on -eq '')
  Bc 'MUST FIRE  a refused row CHEAPER than its store''s cell (Fareway breakfast sausage 0.5225 against 5.32) could move the cell and pages' ($spBy['breakfast-sausage'].page -and $spBy['breakfast-sausage'].paged_on -eq '2026-09-28')
  Bc 'MUST FIRE  a refused row at a store with NO cell for the commodity (Hy-Vee cat food) could put the store on the board and pages' ($spBy['cat-food'].page -and $null -eq $spBy['cat-food'].shadowed_by)
  Bc 'MUST FIRE  a cell whose unit is not the commodity''s (eggs cell in each against dozen) shadows nothing: fail toward paging' ($spBy['eggs'].page)
  $atBar = Set-TcBandPageState (Get-TcBandOpenRows @([pscustomobject]@{ id = 'apple-cider-vinegar'; store = "Baker's"; name = 'at'; unit_price = 0.0546 }) @{} @{} '2026-09-28') @{} $fxCells '2026-09-28'
  Bc 'BAR  a row exactly AT its store''s cell (0.0546 against 0.0546) is shadowed: a tie cannot move the price' (-not $atBar[0].page)
  $pastBar = Set-TcBandPageState (Get-TcBandOpenRows @([pscustomobject]@{ id = 'apple-cider-vinegar'; store = "Baker's"; name = 'past'; unit_price = 0.0545 }) @{} @{} '2026-09-28') @{} $fxCells '2026-09-28'
  Bc 'BAR  one step past it (0.0545 against 0.0546, one unit of the 4-place price) pages' ($pastBar[0].page)
  $bk = Get-TcRefusalKey $bragg
  $d2 = Set-TcBandPageState (Get-TcBandOpenRows @($bragg) @{ $bk = '2026-09-28' } @{} '2026-09-29') @{ $bk = '' } @{} '2026-09-29'
  Bc 'MUST FIRE  the shadowed row pages ONCE the day its cell is gone (never paged, no longer shadowed)' ($d2[0].page -and $d2[0].paged_on -eq '2026-09-29')
  $d3 = Set-TcBandPageState (Get-TcBandOpenRows @($bragg) @{ $bk = '2026-09-28' } @{} '2026-09-30') @{ $bk = '2026-09-29' } @{} '2026-09-30'
  Bc 'MUST NOT FIRE  the day after it paged, the same unshadowed row stays quiet (paged_on 2026-09-29)' (-not $d3[0].page)
  $d4 = Set-TcBandPageState (Get-TcBandOpenRows @($cat) @{ (Get-TcRefusalKey $cat) = '2026-09-26' } @{} '2026-09-28') @{} $fxCells '2026-09-28'
  Bc 'MUST NOT FIRE  an open row written before this rule (no paged_on field, first seen 2026-09-26) paged on its first day and does not page again' ((-not $d4[0].page) -and $d4[0].paged_on -eq '2026-09-26')
  Write-Output ('band-refusals self-test ' + $(if ($bad -eq 0 -and $cases -eq 26) { 'pass' } else { 'FAIL' }) + ': ' + ($cases - $bad) + ' of ' + $cases + ' case(s) (26 expected)')
  exit $(if ($bad -eq 0 -and $cases -eq 26) { 0 } else { 1 })
}

. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\json-io.ps1')
$ff = if ($Date) { Get-Item (Join-Path $OutDir ('flagged-' + $Date + '.json')) -ErrorAction SilentlyContinue } else { Get-ChildItem (Join-Path $OutDir 'flagged-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^flagged-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1 }
if (-not $ff) { Write-Output 'band-refusals: BLIND - no flagged-<date>.json to read'; Write-GuardComplete -Name 'band-refusals' -Summary 'blind=no-flagged'; exit 3 }
$doc = Read-JsonFile $ff.FullName
$res = Invoke-TcBandRefusalAudit @($doc.flagged)
if ($res.examined -eq 0) { Write-Output ('band-refusals: BLIND - ' + $ff.Name + ' carries no band-refused row with a band_ref (built before the derived bands?)'); Write-GuardComplete -Name 'band-refusals' -Summary 'blind=no-band-ref'; exit 3 }
$un = @($res.unexplained)
. (Join-Path $repo 'lib\lf-write.ps1')
$backlog = @{}
$haveBacklog = Test-Path -LiteralPath $BacklogFile
if ($haveBacklog) { foreach ($k in @((Read-JsonFile $BacklogFile).keys)) { if ($k) { $backlog[[string]$k] = $true } } }
if (-not $haveBacklog -and -not $Accept) { Write-Output ('band-refusals: BLIND - no backlog at ' + $BacklogFile + '; record the founding one with -Accept'); Write-GuardComplete -Name 'band-refusals' -Summary 'blind=no-backlog'; exit 3 }
$curKeys = @{}; foreach ($u in $un) { $curKeys[(Get-TcRefusalKey $u)] = $true }
if ($Accept -or $Tighten) {
  # -Tighten may only SHRINK the backlog (keys that still occur survive); -Accept records exactly the current set.
  $keep = if ($Accept) { @($curKeys.Keys) } else { @($backlog.Keys | Where-Object { $curKeys.ContainsKey($_) }) }
  $bdoc = [ordered]@{ note = 'Band-refused rows no basis error explains, by key id|store|name: the matching lane''s worklist (lane:grocery/apply-coverage-batch.ps1). Written only by audit-band-refusals.ps1 -Accept or -Tighten; a plain run never writes it. May only shrink.'; recorded = (Get-Date).ToString('yyyy-MM-dd'); from = $ff.Name; count = $keep.Count; keys = @($keep | Sort-Object) }
  $null = Write-TcLfFile -Path $BacklogFile -Text ($bdoc | ConvertTo-Json -Depth 4) -NoBom
  Write-Output ('band-refusals: backlog ' + $(if ($Accept) { 'ACCEPTED' } else { 'TIGHTENED' }) + ' at ' + $keep.Count + ' key(s) (was ' + $backlog.Count + ')')
  $backlog = @{}; foreach ($k in $keep) { $backlog[[string]$k] = $true }
}
$new = Get-TcNewRefusals $un $backlog
$gone = @($backlog.Keys | Where-Object { -not $curKeys.ContainsKey($_) }).Count
# The open set outside the backlog: first_seen kept per key, decided keys dropped, only first-day keys page.
if (-not $OpenFile) { $OpenFile = Join-Path $OutDir 'band-refusals-open.json' }
if (-not $VerdictFile) { $VerdictFile = Join-Path $root 'match-verdicts.json' }
$today = (Get-Date).ToString('yyyy-MM-dd')
$prevOpen = @{}
$prevPaged = @{}
if (Test-Path -LiteralPath $OpenFile) { foreach ($o in @((Read-JsonFile $OpenFile).rows)) { if ($o -and $o.key) { $prevOpen[[string]$o.key] = [string]$o.first_seen; if ($o.PSObject.Properties['paged_on']) { $prevPaged[[string]$o.key] = [string]$o.paged_on } } } }
$verd = @{}
if (Test-Path -LiteralPath $VerdictFile) { foreach ($v in @((Read-JsonFile $VerdictFile).verdicts)) { if ($v -and $v.key) { $verd[[string]$v.key] = $true } } }
$open = Get-TcBandOpenRows $new $prevOpen $verd $today
# The board built with this flagged file (same date). Absent: no row is shadowed, so every first-day row pages as before.
$boardFile = Join-Path $OutDir (($ff.BaseName -replace '^flagged-', 'comparison-') + '.json')
$haveBoard = Test-Path -LiteralPath $boardFile
$cells = if ($haveBoard) { Get-TcBoardCells (Read-JsonFile $boardFile) } else { @{} }
$open = Set-TcBandPageState $open $prevPaged $cells $today
$page = @($open | Where-Object { $_.page })
$shadowed = @($open | Where-Object { $null -ne $_.shadowed_by })
$odoc = [ordered]@{ note = 'Band-refused rows no basis error explains that are NOT in band-refusals-backlog.json, with first_seen per key id|store|name. Written by every plain run of audit-band-refusals.ps1; read by resolve-match-worklist as kind band. A key pages once, on the first run it is open and not shadowed by a cheaper-or-equal standing cell at its own store (paged_on; shadowed_by names that cell''s price); a match-verdicts.json verdict (band|key) removes it.'; from = $ff.Name; written = $today; count = @($open).Count
  rows = @($open | Sort-Object key | ForEach-Object { [ordered]@{ key = $_.key; first_seen = $_.first_seen; id = [string]$_.row.id; store = [string]$_.row.store; name = [string]$_.row.name; unit_price = $_.row.unit_price; band_ref = $_.row.band_ref; paged_on = [string]$_.paged_on; shadowed_by = $_.shadowed_by } }) }
$null = Write-TcLfFile -Path $OpenFile -Text ($odoc | ConvertTo-Json -Depth 5) -NoBom
Write-Output ('band-refusals: ' + $res.examined + ' band-refused row(s) in ' + $ff.Name + ': ' + $res.explained + ' explained as a basis error, ' + $un.Count + ' unexplained, of which ' + $new.Count + ' NEW (not in the backlog of ' + $backlog.Count + '): ' + $page.Count + ' page (open and able to move a cell, never paged), ' + @($open | Where-Object { $_.new }).Count + ' first seen today, ' + $shadowed.Count + ' shadowed by a cheaper-or-equal standing cell (cannot move the board; board ' + $(if ($haveBoard) { 'read' } else { 'MISSING, nothing shadowed' }) + '), ' + (@($open).Count - @($open | Where-Object { $_.new }).Count) + ' still open from earlier days, ' + ($new.Count - @($open).Count) + ' decided in match-verdicts.json; ' + $gone + ' backlog key(s) no longer occur' + $(if ($gone -gt 0) { ' (ratchet CAN tighten: -Tighten)' } else { '' }))
foreach ($o in ($page | Sort-Object { $_.row.id })) { $u = $o.row; Write-Output ('  UNEXPLAINED  ' + $u.id + ' | ' + $u.store + ' | ' + ('{0:0.####}' -f [double]$u.unit_price) + ' against reference ' + $u.band_ref + ' | ' + $u.name + '   resolver: lane:grocery/resolve-match-worklist.ps1 (a wrong product -> an exclude via apply-coverage-batch -FromWorklist) or the band derivation (a real price)') }
foreach ($o in (@($open | Where-Object { $_.new -and -not $_.page -and $null -ne $_.shadowed_by }) | Sort-Object { $_.row.id })) { $u = $o.row; Write-Output ('  SHADOWED  ' + $u.id + ' | ' + $u.store + ' | ' + ('{0:0.####}' -f [double]$u.unit_price) + ' at or above the standing cell ' + $o.shadowed_by + ' | ' + $u.name) }
foreach ($o in (@($open | Where-Object { -not $_.new }) | Sort-Object { $_.row.id })) { $u = $o.row; Write-Output ('  OPEN since ' + $o.first_seen + '  ' + $u.id + ' | ' + $u.store + ' | ' + $u.name) }
Write-GuardComplete -Name 'band-refusals' -Summary ('scanned=' + $res.examined + ' explained=' + $res.explained + ' unexplained=' + $un.Count + ' findings=' + $page.Count + ' open=' + @($open).Count + ' shadowed=' + $shadowed.Count + ' backlog=' + $backlog.Count)
exit $(if ($page.Count -gt 0) { 2 } else { 0 })

