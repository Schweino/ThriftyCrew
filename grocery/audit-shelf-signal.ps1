<#
  audit-shelf-signal.ps1 - how much of the Walmart board is priced off a listing that only SHIPS?

  ADVISORY BY DESIGN. This never sets a failing exit code and nothing gates on it. That is not timidity,
  it is the spec: design\BRIEF-marketplace-shelf-signal-2026-08-29.md says the rule must not gate until
  per-department coverage is measured, and this file is the instrument that measures it. A gate armed on a
  signal nobody has counted is how this estate got the allowlist bug of 2026-07-30 - two entries justified
  by "the store does not carry the item" while the store carried it.

  WHAT IT IS FOR. Three generations of per-product known-wrong rulings failed to converge on the
  marketplace-bulk class: Frontier Co-op 16 oz bags -> 27 Peaks Gourmet 12-19 oz bottles -> Badia 16 oz,
  24 Mantra, Spice Hut. curry-powder was blocked at Frontier's $0.7669/oz and came back at 27 Peaks'
  $0.7775/oz, one cent dearer, then again at Badia. A ruling names a PRODUCT; the defect is a LISTING KIND.
  The one fact that separates them was on the page and not in our data - is this purchasable at the L St
  store, or does it only ship? - so build-walmart-deals now carries seller + fulfillment onto every row and
  this reports what they say.

  THREE THINGS IT PRINTS, and the first is the one that matters most today:
    1. COVERAGE - how many priced Walmart cells carry any signal at all. Until that is most of them, no
       verdict here is worth gating on, because the 90-day union is full of captures written before the
       SKILL emitted the columns and their silence is not evidence.
    2. SHIP-ONLY - cells whose row says fulfillment=SHIP with a first-party seller. This is the class the
       existing 3P filter misses BY CONSTRUCTION: import-walmart-batch.ps1:104 treats STORE/FC/SHIP alike
       as first-party and keeps them, because it was built to catch third-party SELLERS, not shelf-absence.
    3. THIRD-PARTY - seller is neither empty nor Walmart(.com). Those should already have been dropped at
       import; any that reach the board mean the filter did not run on that capture.

  THE ENUM WAS MEASURED LIVE, AND THE FIRST GUESS WAS WRONG (2026-08-29, Brad's Chrome). This file
  originally classified STORE and FC together as SHELF and reserved SHIP-ONLY for fulfillmentType=SHIP,
  reasoning from import-walmart-batch's comment that "STORE / FC / SHIP (first-party, keep)". Two live
  search pages say otherwise, and they carry their own control - unrelated tiles on the SAME page offering
  pickup:

    harissa paste   every result "Shipping, arrives ..."      -> fulfillmentType FC   (incl. seller Walmart.com)
                    sriracha tiles "Pickup as soon as ..."     -> fulfillmentType STORE
    ground cumin    Great Value Ground Cumin 2.5 oz (pickup)   -> STORE
                    McCormick Kosher Ground Cumin 4.5 oz       -> FC, seller Walmart.com
                    Good Tierra 21 oz Bulk Cumin               -> FC, seller MEKOR LLC
                    Bolner's Fiesta Comino                     -> MARKETPLACE

  So FC is FULFILLMENT CENTRE - shipped from a warehouse, NOT on the L St shelf - and it is the ship-only
  marker, not SHIP. SHIP did not appear in either page's enum at all. Crucially FC occurs with
  sellerName='Walmart.com', so it is invisible to a SELLER test: that is precisely why
  import-walmart-batch.ps1:104's 3P filter (which keeps STORE/FC/SHIP alike as first-party) let the whole
  Frontier / 27 Peaks / Badia bulk class through. The seller filter is not wrong - those really are
  first-party listings - it is answering a different question from "is this on the shelf".

  This is why the refusal was never armed on the inferred enum: the inference was wrong, and a gate built
  on it would have refused every STORE cell it should keep while admitting the FC ones it exists to catch.

  Usage:  audit-shelf-signal.ps1            (exit 0 always; 3 only if it could not read a board)
          audit-shelf-signal.ps1 -SelfTest
#>
param(
  [string]$Root,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
$outDir = Join-Path $Root 'out'

function Say([string]$m) { Write-Output $m }

# THE CLASSIFIER, kept as one function so the self-test grades the same code the report runs.
# '' is UNKNOWN and must never be read as shipped - see build-walmart-deals' note on the 90-day union.
function Get-ShelfVerdict([string]$seller, [string]$fulfill) {
  $s = ([string]$seller).Trim()
  $f = ([string]$fulfill).Trim().ToUpper()
  if ($f -eq '' -and $s -eq '') { return 'UNKNOWN' }
  $firstParty = ($s -eq '' -or $s -match '(?i)^walmart(\.com)?$')
  if (-not $firstParty) { return 'THIRD-PARTY' }
  if ($f -eq 'MARKETPLACE') { return 'THIRD-PARTY' }
  if ($f -eq 'STORE') { return 'SHELF' }
  if ($f -eq 'FC' -or $f -eq 'SHIP') { return 'SHIP-ONLY' }
  return 'UNKNOWN'
}

if ($SelfTest) {
  $fail = 0; $pass = 0
  function T($cond, $msg) { if ($cond) { Say ('  PASS  ' + $msg); $script:pass++ } else { Say ('  FAIL  ' + $msg); $script:fail++ } }
  Say 'audit-shelf-signal -SelfTest'
  # THE SAFETY PROPERTY FIRST. Every capture in the 90-day union predates these columns; if absence read
  # as anything but UNKNOWN this file would indict most of the Walmart board on no evidence.
  T ((Get-ShelfVerdict '' '') -eq 'UNKNOWN') 'no seller and no fulfillment is UNKNOWN, never SHIP-ONLY (the whole pre-2026-08-29 union looks like this)'
  # MEASURED LIVE 2026-08-29 on walmart.com in Brad's Chrome, two search pages, each carrying its own
  # control (unrelated tiles offering pickup on the same page). These four are the enum as it really is.
  T ((Get-ShelfVerdict 'Walmart.com' 'STORE') -eq 'SHELF') 'STORE is the shelf marker (Great Value Ground Cumin 2.5 oz, pickup offered)'
  T ((Get-ShelfVerdict 'Walmart.com' 'FC') -eq 'SHIP-ONLY') 'FC is FULFILLMENT CENTRE and ship-only EVEN WHEN first-party (McCormick Kosher Cumin 4.5 oz, seller Walmart.com, no pickup)'
  T ((Get-ShelfVerdict '' 'FC') -eq 'SHIP-ONLY') 'an empty seller is first-party, so empty + FC is still SHIP-ONLY'
  T ((Get-ShelfVerdict 'Walmart.com' 'SHIP') -eq 'SHIP-ONLY') 'SHIP is treated as ship-only too, though it did not appear in either live page'
  T ((Get-ShelfVerdict 'Walmart.com' 'MARKETPLACE') -eq 'THIRD-PARTY') 'MARKETPLACE is third-party even under a Walmart.com seller string'
  T ((Get-ShelfVerdict 'Pool Cue Emporium' 'MARKETPLACE') -eq 'THIRD-PARTY') 'a 3P seller is THIRD-PARTY (the Goya-beans pool-cue-shop bug)'
  T ((Get-ShelfVerdict 'Pool Cue Emporium' 'FC') -eq 'THIRD-PARTY') 'seller beats fulfillment: an FC-fulfilled 3P listing is still third-party'
  T ((Get-ShelfVerdict 'Walmart.com' 'SOMETHING-NEW') -eq 'UNKNOWN') 'an unrecognised fulfillment value is UNKNOWN, not a verdict - Walmart has moved this schema twice already'
  # And it must be advisory: a failing exit code here would gate the publish on an uncounted signal.
  # Scoped to the REPORT half deliberately: the first version grepped the whole file and matched this
  # self-test's own failure exit, which is legitimate. A check that fails on itself teaches nothing.
  $src = Get-Content $PSCommandPath -Raw
  $reportHalf = ($src -split '(?m)^# -+ the board')[-1]
  T ($reportHalf -notmatch 'exit 2') 'the REPORT path has no exit-2 - it is advisory and cannot gate a publish'
  T ($reportHalf -match 'exit 3') 'the report path CAN exit 3 (blind), because "could not measure" must not read as "clean"'
  if ($fail -gt 0) { Say ("audit-shelf-signal SELFTEST: $fail FAILED"); exit 2 }
  Say ("audit-shelf-signal SELFTEST: all $pass passed"); exit 0
}

# ---------------------------------------------------------------- the board
$cmp = @(Get-ChildItem (Join-Path $outDir 'comparison-*.json') -ErrorAction SilentlyContinue |
         Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1)
if (-not $cmp.Count) { Say 'SHELF-SIGNAL BLIND: no comparison-*.json to read - nothing was measured, which is not the same as nothing being wrong.'; exit 3 }
$board = $null
try { $board = Get-Content $cmp[0].FullName -Raw | ConvertFrom-Json } catch { $board = $null }
if (-not $board) { Say ("SHELF-SIGNAL BLIND: " + $cmp[0].Name + ' would not parse.'); exit 3 }

# ---------------------------------------------------------------- the signal, by product name
$sig = @{}
$files = @(Get-ChildItem (Join-Path $outDir 'regular\walmart-regular-*.json') -ErrorAction SilentlyContinue | Sort-Object Name)
foreach ($f in $files) {
  try { $d = Read-JsonFile $f.FullName } catch { continue }
  foreach ($r in @($d.deals)) {
    if (-not $r) { continue }
    $n = [string]$r.item
    if (-not $n) { continue }
    $p = @($r.PSObject.Properties.Name)
    $sel = if ($p -contains 'seller') { [string]$r.seller } else { '' }
    $ff  = if ($p -contains 'fulfillment') { [string]$r.fulfillment } else { '' }
    # newest file wins, so a re-captured row's fresher signal replaces an older silence
    $sig[$n] = @{ seller = $sel; fulfill = $ff }
  }
}

$counts = @{ 'SHELF' = 0; 'SHIP-ONLY' = 0; 'THIRD-PARTY' = 0; 'UNKNOWN' = 0 }
$flagged = New-Object System.Collections.Generic.List[object]
$cells = 0
foreach ($row in @($board.comparison)) {
  $stores = @($row.stores)
  for ($i = 0; $i -lt $stores.Count; $i++) {
    $s = $stores[$i]
    if ([string]$s.store -ne 'Walmart') { continue }
    $n = [string]$s.item
    if (-not $n) { continue }
    $cells++
    $sel = ''; $ff = ''
    if ($sig.ContainsKey($n)) { $sel = [string]$sig[$n].seller; $ff = [string]$sig[$n].fulfill }
    $v = Get-ShelfVerdict $sel $ff
    $counts[$v] = $counts[$v] + 1
    if ($v -eq 'SHIP-ONLY' -or $v -eq 'THIRD-PARTY') {
      [void]$flagged.Add([pscustomobject]@{ id = [string]$row.id; crown = ($i -eq 0); verdict = $v; per_unit = $s.per_unit; item = $n; seller = $sel; fulfillment = $ff })
    }
  }
}

$known = $counts['SHELF'] + $counts['SHIP-ONLY'] + $counts['THIRD-PARTY']
$pct = if ($cells -gt 0) { [math]::Round(100.0 * $known / $cells, 1) } else { 0 }
Say ("shelf-signal: " + $cells + " named Walmart cell(s) on " + $cmp[0].BaseName + "; " + $known + " carry a signal (" + $pct + "%), " + $counts['UNKNOWN'] + " unknown")
Say ("  SHELF " + $counts['SHELF'] + "   SHIP-ONLY " + $counts['SHIP-ONLY'] + "   THIRD-PARTY " + $counts['THIRD-PARTY'] + "   UNKNOWN " + $counts['UNKNOWN'])
if ($known -eq 0) {
  Say '  NO SIGNAL YET. Every Walmart capture in the union predates the sel/ff columns, so this reports'
  Say '  nothing about the board and must not be read as a clean result. It starts saying something after'
  Say '  the next attended-Chrome Walmart pull writes a 9-column capture.'
}
foreach ($x in @($flagged | Sort-Object @{e={-[int][bool]$_.crown}}, id)) {
  Say ("  " + $(if ($x.crown) { 'CROWN ' } else { '      ' }) + $x.verdict.PadRight(12) + ([string]$x.id).PadRight(26) + ([string]$x.per_unit).PadRight(10) + $x.item)
  Say ("            seller='" + $x.seller + "' fulfillment='" + $x.fulfillment + "'")
}
if ($counts['SHIP-ONLY'] -gt 0) {
  Say '  SHIP-ONLY is a QUESTION, not a verdict: nobody has yet checked what fulfillmentType a KNOWN-SHELF'
  Say '  item reports. Confirm that against one before anything is ruled or gated on it.'
}
$rep = Join-Path $outDir 'shelf-signal.json'
# Built key by key into an ordered dictionary. The one-shot [pscustomobject]@{...} form threw
# "Argument types do not match" on PS 5.1 with a nested hashtable in it - and it threw AFTER the report
# had already printed, so the finding was on screen and the file was never written.
$doc = [ordered]@{}
$doc['generated']    = (Get-Date).ToString('s')
$doc['board']        = [string]$cmp[0].BaseName
$doc['cells']        = [int]$cells
$doc['coverage_pct'] = [double]$pct
$doc['counts']       = [ordered]@{ SHELF = [int]$counts['SHELF']; 'SHIP_ONLY' = [int]$counts['SHIP-ONLY']
                                   'THIRD_PARTY' = [int]$counts['THIRD-PARTY']; UNKNOWN = [int]$counts['UNKNOWN'] }
# PS 5.1 threw "Argument types do not match" assigning a List[object] into an OrderedDictionary
# entry, even wrapped in @(). Materialise it to a plain object[] first. This threw AFTER the report
# had printed, so the screen looked complete while the JSON was never written - the same
# looks-finished-but-wrote-nothing shape as a capture that reads the wrong path and returns empty.
$flagArr = [object[]]($flagged.ToArray())
$doc['flagged']      = $flagArr
(New-Object psobject -Property $doc) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $rep -Encoding UTF8
Say ("  -> " + $rep)
Say 'SHELF-SIGNAL-COMPLETE'
exit 0
