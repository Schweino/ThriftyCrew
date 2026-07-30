<#
  import-walmart-batch.ps1 - turn the Walmart __NEXT_DATA__ capture (name~~linePrice~~unitPrice~~usItemId per
  product, tab-keyed by commodity) into walmart-regular rows.

  *** EVERY ROW GOES THROUGH THE BUILDER'S OWN VERIFICATION (2026-07-30 refactor) ***
  This script used to carry its own, weaker size math (back the size out of Walmart's unit price, round to ONE
  decimal, no engine check, no multipack filter). Measured cost on the 23 rows it put into
  walmart-regular-2026-07-25.json: 6 of 23 failed build-walmart-deals' engine-reproduces-the-unit-price
  invariant (3.3-7.1% off), and one of them was CROWNED cheapest on the 2026-07-29 board
  (brown-gravy-mix at $0.5333/oz vs Walmart's real $0.552/oz). So now the importer LIFTS Build-Row out of
  build-walmart-deals.ps1 - the same AST extraction the builder itself uses on compare-deals.ps1 - and every
  batch row must pass:
    1. Build-Row: exact size from Walmart's own arithmetic (lp/up), name-snap when the name reproduces the
       unit price, package-vs-per-unit shape decided by the REAL engine, and the emit invariant:
       Get-UnitPrice(row) must reproduce Walmart's own unitPrice or the row is rejected, never published.
    2. The 2026-07-27 fish-sauce rule (kept from the old importer; Build-Row alone would REGRESS it):
       Walmart's unit price is occasionally WRONG, and lp/up then backs out a wrong size. When the name
       states a single same-family size that diverges >10% from Build-Row's quantity, the NAME wins - and the
       overridden shape is re-verified through the real engine against lp/nameQty. The override is stamped
       into qty_basis so the divergence is visible in the file.
    3. The guard-5 multipack pre-filter (multipack-lib.ps1, dot-sourced same as the builder) - a row guard 5
       would hard-fail is rejected at ingest, by construction.
  Writer provenance: every row carries written_by='import-walmart-batch.ps1' + seller_check, and the merged
  file gets a batch_imports stamp - so a divergent row can be traced to its writer instead of hiding under
  the builder's "every row verified" header.

  NOTE: store is Bellevue 68123 (Omaha metro, Brad OK'd 2026-07-15 - Walmart zone-prices are uniform across the
  metro). Usage: .\import-walmart-batch.ps1 [-TrustNoSeller] ; then compare-deals -> diff-board -> vet.
  -OutRoot writes out\regular + the itemid map under a different root (sandbox testing; default = live).
#>
param([string]$Raw = 'out\staples500\walmart-batch1-raw.txt', [switch]$SelfTest, [switch]$TrustNoSeller, [string]$OutRoot = '')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$today = (Get-Date).ToString('yyyy-MM-dd')
$outRootDir = if ($OutRoot) { $OutRoot } else { $root }
$regDir = Join-Path $outRootDir 'out\regular'

# ---- lift the REAL pricing math + the REAL row builder (one rule, one home - the importer borrows, never forks) ----
$engineSrc = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
foreach ($fn in @('ConvertTo-DigitNumerals','Get-ItemPrice','Get-PackCount','Get-UnitPrice','Get-SizeAmount','Convert-ToUnit')) {
  $m = [regex]::Match($engineSrc, "(?ms)^function\s+$([regex]::Escape($fn))\s*\(.*?^\}")
  if (-not $m.Success) { throw "import-walmart-batch: could not lift $fn from compare-deals.ps1" }
  Invoke-Expression $m.Value
}
$builderSrc = Get-Content (Join-Path $root 'build-walmart-deals.ps1') -Raw
foreach ($fn in @('Resolve-Unit','Get-NameQtyCandidates','Get-NamePack','Format-Qty','Build-Row')) {
  $m = [regex]::Match($builderSrc, "(?ms)^function\s+$([regex]::Escape($fn))\s*\(.*?^\}")
  if (-not $m.Success) { throw "import-walmart-batch: could not lift $fn from build-walmart-deals.ps1" }
  Invoke-Expression $m.Value
}
$m = [regex]::Match($builderSrc, '(?ms)^\$script:UnitFamily = @\{.*?^\}')
if (-not $m.Success) { throw 'import-walmart-batch: could not lift $script:UnitFamily from build-walmart-deals.ps1' }
Invoke-Expression $m.Value
. (Join-Path $root 'multipack-lib.ps1')      # guard-5 lockstep, exactly as the builder dot-sources it
$script:iwbAllow = Get-MpAllowKeys $root

# Walmart's own unit price is occasionally WRONG, and backing the size out of it then ships a wrong
# per-unit price (2026-07-27: "Kikkoman Gluten-Free Fish Sauce, 6.8 fl oz" was listed at 28.4 c/fl oz,
# which backs out to 10 fl oz - the store page itself says 6.8 fl oz, so we published $0.284/fl oz
# instead of $0.418, understating by 32%). The product NAME is the seller's stated pack size and beat
# the computed unit price every time we checked, so when the two disagree the NAME wins.
function Parse-NameSize([string]$name) {
  if (-not $name) { return $null }
  # packs legitimately multiply the stated unit size - no clean single-unit claim to trust
  if ($name -match '(?i)\b\d+\s*(ct|count|pk|packs?)\b' -or $name -match '(?i)\b(twin|multi|variety|value)\s*pack\b') { return $null }
  # weight RANGES ("1.0 - 3.0 lb") state no single size
  if ($name -match '(?i)\d[\d.]*\s*-\s*\d[\d.]*\s*(fl\s*oz|floz|oz|lbs?)\b') { return $null }
  # nutrition text ("16g Protein Per Serving", "4oz 112g") is not a pack size
  $clean = $name -replace '(?i)\d+\s*g\b[^,]*?protein[^,]*', '' -replace '(?i)\bper\s+serving\b', ''
  $ms = [regex]::Matches($clean, '(?i)(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|lbs?)\b')
  if ($ms.Count -eq 0) { return $null }
  $m = $ms[$ms.Count - 1]          # the size conventionally trails the name
  $qty = [double]$m.Groups[1].Value
  if ($qty -le 0) { return $null }
  $raw = ($m.Groups[2].Value.ToLower() -replace '\s+', '')
  $u = 'oz'; if ($raw -match '^fl') { $u = 'fl oz' } elseif ($raw -match '^lb') { $u = 'lb' }
  return ("$qty $u")
}

# The in-store seller gate. 6-field captures prove first-party; 4-field captures CANNOT, and warn-and-keep
# already cost us once: 15 of the 38 rows in the r300 capture were 3P marketplace listings (a pool-cue shop
# was the "Walmart price" for Goya pigeon peas) that had to be hand-pruned - any re-run would have silently
# re-imported them. Default is now QUARANTINE; -TrustNoSeller restores import for a hand-verified capture
# and stamps seller_check='manual-trust' on every row it lets through.
function Test-IwbSeller($fields, [bool]$trust) {
  if (@($fields).Count -ge 6) {
    $seller = ([string]$fields[4]).Trim(); $fulfill = ([string]$fields[5]).Trim().ToUpper()
    $firstParty = ($fulfill -eq 'STORE' -or $fulfill -eq 'FC' -or $fulfill -eq 'SHIP') -and
                  ($seller -eq '' -or $seller -match '(?i)^walmart(\.com)?$')
    if ($fulfill -eq 'MARKETPLACE' -or -not $firstParty) { return @{ drop3p = $true; seller = $seller; fulfill = $fulfill } }
    return @{ take = $true; check = 'capture' }
  }
  if ($trust) { return @{ take = $true; check = 'manual-trust' } }
  return @{ quarantine = $true }
}

# One raw batch product -> a fully verified board row (or @{err=..}). This is the whole point of the file:
# a row this returns is a row build-walmart-deals would have emitted, plus the fish-sauce name override.
function Convert-BatchRow($raw, [System.Collections.ArrayList]$log) {
  $b = Build-Row $raw
  if ($b.err) { return $b }
  $row = $b.row
  # fish-sauce rule: name single-size (same family) diverging >10% from the emitted quantity -> name wins
  $named = Parse-NameSize $row.item
  $em = [regex]::Match([string]$row.size, '^([\d.]+)\s+(lb|oz|fl oz)$')
  if ($named -and $em.Success) {
    $pn = [regex]::Match($named, '^([\d.]+)\s+(.+)$')
    $famE = $(if ($em.Groups[2].Value -eq 'fl oz') { 'vol' } else { 'wt' })
    $famN = $(if ($pn.Groups[2].Value -eq 'fl oz') { 'vol' } else { 'wt' })
    if ($famE -eq $famN) {
      $ozE = [double]$em.Groups[1].Value; if ($em.Groups[2].Value -eq 'lb') { $ozE *= 16 }
      $ozN = [double]$pn.Groups[1].Value; if ($pn.Groups[2].Value -eq 'lb') { $ozN *= 16 }
      if ($ozE -gt 0 -and $ozN -gt 0 -and [math]::Abs($ozN / $ozE - 1) -gt 0.10) {
        # the overridden shape must STILL parse through the real engine to lp/nameQty - shape verification
        # is unconditional even when we deliberately distrust Walmart's unit price
        $lp = 0.0; [void][double]::TryParse((([string]$row.ad_price) -replace '[^0-9.]', ''), [ref]$lp)
        $qtyN = [double]$pn.Groups[1].Value
        $unit = $(if ($pn.Groups[2].Value -eq 'fl oz') { 'floz' } elseif ($pn.Groups[2].Value -eq 'lb') { 'lb' } else { 'oz' })
        $want = $lp / $qtyN
        $chk = Get-UnitPrice ([pscustomobject]@{ price_text = $row.ad_price; name = $row.item; size_text = $named; regular = $null }) ([pscustomobject]@{ unit = $unit })
        if ($null -ne $chk -and $want -gt 0 -and ([math]::Abs($chk.unit_price - $want) / $want) -le 0.02) {
          [void]$log.Add(("{0}  Walmart unit price implies [{1}] but the name states [{2}] - using the name" -f $row.item, $row.size, $named))
          $row.size = $named
          $row.qty_basis = ($row.qty_basis + '; OVERRIDDEN by name size ' + $named + ' (fish-sauce rule 2026-07-27: Walmart''s own unit price ' + $row.wm_unit_price + ' distrusted)')
          $row.engine_check = ('' + [math]::Round($chk.unit_price, 4) + '/' + $unit + ' [' + $chk.basis + '] vs name-implied ' + [math]::Round($want, 4))
        }
      }
    }
  }
  # guard-5 lockstep: reject at ingest exactly what the publish gate would hard-fail
  if ((Test-MpClassify 'Walmart' ([string]$row.item) ([string]$row.size) $script:iwbAllow) -eq 'reject') {
    return @{ err = 'multipack: pack priced as a single board unit (guard 5) - not a shopper single-buy unit' }
  }
  # writer provenance: visible in the file, per row
  $row.source_ad = 'Walmart Bellevue 68123 shelf price (batch capture)'
  $row | Add-Member -NotePropertyName written_by -NotePropertyValue 'import-walmart-batch.ps1' -Force
  return @{ row = $row }
}

if ($SelfTest) {
  # Pure computation, no writes. Locks (a) the 2026-07-25 one-decimal rounding bug through the builder
  # invariant, (b) the 2026-07-27 fish-sauce override ON TOP of Build-Row (Build-Row alone regresses it),
  # (c) the guard-5 multipack lockstep, (d) the malformed-unit-price rejects the old parser crashed on,
  # (e) the seller gate. Expectations were measured through the real lifted engine on 2026-07-30.
  $CENT = [string][char]0x00A2
  $fail = 0
  $log = New-Object System.Collections.ArrayList
  function _R($n, $lp, $up) { [pscustomobject]@{ q = 't'; n = $n; lp = $lp; up = $up; id = '1' } }
  $cases = @(
    # THE FOUNDING BUG (live on the 2026-07-29 board as the brown-gravy-mix CROWN): old path rounded the
    # backed-out 0.8696 oz to "0.9 oz" and published $0.5333/oz vs Walmart's real $0.552/oz.
    @{ n='Great Value Brown Gravy Mix, 0.87 oz Packet';                lp='$0.48';  up=('55.2 ' + $CENT + '/oz'); e='0.87 oz';    ad='$0.48'  }
    # worst live drift of the 23: rounding shipped 7.1% under Walmart's own number
    @{ n='McCormick Kosher Poultry Seasoning, 0.65 oz Bottle';         lp='$3.18';  up='$4.89/oz';                e='0.65 oz';    ad='$3.18'  }
    # when no name qty reproduces the unit price, the derived size stays EXACT (old path rounded 1.298 -> 1.3)
    @{ n='Tyson All Natural Chicken Livers, 1.25 lb';                  lp='$1.96';  up='$1.51/lb';                e='1.298 lb';   ad='$1.96'  }
    # 2026-07-27 fish-sauce incident: lp/up backs out 10 fl oz, the bottle says 6.8 - the NAME wins
    @{ n='Kikkoman Gluten-Free Fish Sauce, 6.8 fl oz Glass Bottle';    lp='$2.84';  up=('28.4 ' + $CENT + '/fl oz'); e='6.8 fl oz'; ad='$2.84'; ovr=$true }
    # clean twin: name agrees -> name-snap inside Build-Row, exact name size, NO override stamped
    @{ n='Thai Kitchen Gluten Free Premium Fish Sauce, 6.76 fl oz';    lp='$4.76';  up=('70.0 ' + $CENT + '/fl oz'); e='6.76 fl oz'; ad='$4.76' }
    # a WEIGHT name size must never override a VOLUME unit price (cross-family)
    @{ n='Some Sauce, 32 oz Jar';                                      lp='$6.40';  up=('10.0 ' + $CENT + '/fl oz'); e='64 fl oz';  ad='$6.40'  }
    # per-lb marker in the name: the engine reads ad_price AS the per-lb price, so the per-unit shape must
    # win. The old importer never ran the engine and would have shipped the $10.35 tray as $10.35/LB.
    @{ n="Member's Mark Boneless Skinless Chicken Breast, priced per pound"; lp='$10.35'; up='$2.88/lb';           e='lb';         ad='$2.88'  }
    # a weight RANGE states no single size -> derived, exact
    @{ n='Sanderson Farms Whole Chicken, 11.0 - 12.2 lb';              lp='$15.27'; up='$1.32/lb';                e='11.568 lb';  ad='$15.27' }
    # nutrition grams are not a pack size
    @{ n='Armour Corned Beef Hash, 16g Protein Per Serving, 14 oz';    lp='$2.72';  up=('19.4 ' + $CENT + '/oz'); e='14 oz';      ad='$2.72'  }
  )
  foreach ($c in $cases) {
    $r = Convert-BatchRow (_R $c.n $c.lp $c.up) $log
    if ($r.err) { Write-Output "FAIL  [$($c.n)] -> $($r.err)"; $fail++; continue }
    $ovrStamped = ([string]$r.row.qty_basis -match 'OVERRIDDEN by name')
    if ($r.row.size -ne $c.e -or $r.row.ad_price -ne $c.ad) { Write-Output "FAIL  [$($c.n)] got ad=$($r.row.ad_price) size='$($r.row.size)' want ad=$($c.ad) size='$($c.e)'"; $fail++ }
    elseif ([bool]$c.ovr -ne $ovrStamped) { Write-Output "FAIL  [$($c.n)] override stamped=$ovrStamped want $([bool]$c.ovr)"; $fail++ }
    else { Write-Output "ok    [$($c.n)] -> ad=$($r.row.ad_price) size='$($r.row.size)'" }
  }
  # rows that must be REJECTED, never published
  $rejCases = @(
    @{ n='Great Value Vanilla Ice Cream Sandwiches, 42 fl oz, 12 Pack'; lp='$5.96'; up=('14.2 ' + $CENT + '/fl oz'); want='multipack' }   # guard-5 lockstep
    @{ n='(4 pack) Skinner Thin Spaghetti Pasta, 12-Ounce Bag';         lp='$4.75'; up=('9.9 ' + $CENT + '/oz');     want='multipack' }   # old importer SHIPPED this; guard 5 would have blocked the publish
    @{ n='Malformed Unit Price';                                        lp='$5.00'; up='1.2.3/oz';                   want='no unitPrice' } # old Parse-WMSize THREW here and EAP=Stop killed the whole import
    @{ n='Leading Dot Cents';                                           lp='$2.00'; up=('.9 ' + $CENT + '/oz');     want='no unitPrice' } # old path backed a fabricated 222.2 oz size out of this
  )
  foreach ($c in $rejCases) {
    $r = Convert-BatchRow (_R $c.n $c.lp $c.up) $log
    if ($r.err -and $r.err -match $c.want) { Write-Output "ok    rejects [$($c.n)] -> $($r.err)" }
    else { Write-Output "FAIL  [$($c.n)] should have been rejected ($($c.want)), got $(if($r.err){$r.err}else{'size '+$r.row.size})"; $fail++ }
  }
  # MUST-FIRE: the exact shape the old importer shipped on 2026-07-25 does NOT verify through the engine -
  # this is the check that was missing, demonstrated on the founding bug's frozen row.
  $old = Get-UnitPrice ([pscustomobject]@{ price_text = '$0.48'; name = 'Great Value Brown Gravy Mix, 0.87 oz Packet'; size_text = '0.9 oz'; regular = $null }) ([pscustomobject]@{ unit = 'oz' })
  $wm = 0.552; $tol = [math]::Max(0.02, (0.005 / $wm) + 0.005)
  if ($old -and (([math]::Abs($old.unit_price - $wm) / $wm) -gt $tol)) { Write-Output ("ok    MUST-FIRE: the shipped 0.9-oz shape fails the builder tolerance (engine " + [math]::Round($old.unit_price,4) + " vs Walmart 0.552, tol " + [math]::Round($tol*100,1) + "%)") }
  else { Write-Output 'FAIL  the founding-bug shape passed the tolerance - the invariant went blind'; $fail++ }
  # writer provenance is stamped on every emitted row
  $p = (Convert-BatchRow (_R 'Great Value Poultry Seasoning, 1.5 oz' '$1.97' '$1.31/oz') $log).row
  if ($p.written_by -eq 'import-walmart-batch.ps1' -and $p.source_ad -match 'batch capture' -and $p.engine_check) { Write-Output 'ok    provenance: written_by + batch source_ad + engine_check on every row' }
  else { Write-Output 'FAIL  provenance fields missing'; $fail++ }
  # seller gate
  $s1 = Test-IwbSeller @('n','$1','$1/oz','1','Pool Cue Emporium','MARKETPLACE') $false
  $s2 = Test-IwbSeller @('n','$1','$1/oz','1') $false
  $s3 = Test-IwbSeller @('n','$1','$1/oz','1') $true
  $s4 = Test-IwbSeller @('n','$1','$1/oz','1','','STORE') $false
  if ($s1.drop3p -and $s2.quarantine -and $s3.check -eq 'manual-trust' -and $s4.check -eq 'capture') { Write-Output 'ok    seller gate: 3P dropped, seller-less quarantined by default, -TrustNoSeller stamped, 6-field first-party passes' }
  else { Write-Output 'FAIL  seller gate'; $fail++ }
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

# Raw row format (~~-delimited): name~~linePrice~~unitPrice~~usItemId[~~sellerName~~fulfillmentType]
# The last two fields are OPTIONAL (6-field reducer, 2026-07-26): a 3P MARKETPLACE listing is NOT a Bellevue
# shelf price and violates the in-store rule. Present -> non-first-party rows are DROPPED. Absent -> the row
# is QUARANTINED to out\walmart-batch-needs-seller-<date>.json (see Test-IwbSeller above for why warn-and-keep
# was not enough); -TrustNoSeller imports a hand-verified capture and stamps it. Update the browser reducer:
#   ...+'~~'+(p.sellerName||'')+'~~'+(((p.fulfillmentType)||'').toUpperCase())
# READ THE CAPTURE AS UTF-8, AND REPAIR ANYTHING ALREADY MANGLED UPSTREAM.
# A browser Blob download is UTF-8; PowerShell 5.1's Get-Content defaults to the system ANSI codepage
# (Windows-1252 here), so a bare read corrupts every non-ASCII byte and then the row is SAVED that way - the
# damage is baked into the bytes, so reading correctly later does not undo it. That shipped 16 mangled board
# rows on 2026-07-29, 6 of them CROWNS. Walmart hits EVERY line because its unit price carries a cent glyph -
# so the corruption lands in the PRICE field, not just the name. Repair-Mojibake is a no-op on clean text.
. (Join-Path $root 'capture-lib.ps1')
$lines = @(Get-Content (Join-Path $root $Raw) -Encoding UTF8) | ForEach-Object { Repair-Mojibake $_ }   # test-auditors.ps1 greps this exact read shape - keep it verbatim
$rows = New-Object System.Collections.ArrayList
$ids = @{}
$dropped3P = New-Object System.Collections.ArrayList
$quarantined = New-Object System.Collections.ArrayList
$rejects = New-Object System.Collections.ArrayList
$overrides = New-Object System.Collections.ArrayList
foreach ($ln in $lines) {
  if (-not ($ln -match "`t")) { continue }
  $prodStr = ($ln -split "`t", 2)[1]
  foreach ($p in ($prodStr -split '\|')) {
    $f = $p -split '~~'
    if ($f.Count -lt 3) { continue }
    $nm = ($f[0]).Trim()
    if (-not $nm) { continue }
    $itemId = ''; if ($f.Count -ge 4) { $itemId = ($f[3]).Trim() }
    $sv = Test-IwbSeller $f $TrustNoSeller.IsPresent
    if ($sv.drop3p) { [void]$dropped3P.Add(("{0}  [seller={1}, fulfill={2}]" -f $nm, $sv.seller, $sv.fulfill)); continue }
    if ($sv.quarantine) { [void]$quarantined.Add([pscustomobject]@{ name = $nm; lp = [string]$f[1]; up = [string]$f[2]; id = $itemId; reason = 'no seller/fulfillment fields - marketplace filter cannot run; re-capture with the 6-field reducer, or hand-verify sellers and re-run with -TrustNoSeller' }); continue }
    $res = Convert-BatchRow ([pscustomobject]@{ q = ''; n = $nm; lp = [string]$f[1]; up = [string]$f[2]; id = $itemId }) $overrides
    if ($res.err) { [void]$rejects.Add([pscustomobject]@{ name = $nm; lp = [string]$f[1]; up = [string]$f[2]; reason = $res.err }); continue }
    $row = $res.row
    $row | Add-Member -NotePropertyName as_of -NotePropertyValue $today -Force
    $row | Add-Member -NotePropertyName seller_check -NotePropertyValue $sv.check -Force
    [void]$rows.Add($row)
    if ($itemId) { $ids[$nm] = $itemId }
  }
}
if ($dropped3P.Count -gt 0) { Write-Output ("Walmart: DROPPED {0} third-party/marketplace row(s) (in-store rule):" -f $dropped3P.Count); $dropped3P | ForEach-Object { Write-Output ('  - ' + $_) } }
if ($overrides.Count -gt 0) { Write-Output ("Walmart: {0} row(s) where the name size beat Walmart's own unit price:" -f $overrides.Count); $overrides | ForEach-Object { Write-Output ('  - ' + $_) } }

# REPLACE-by-identity merge into today's walmart-regular. ADD-only (item|size key) kept BOTH a corrected row
# and the row it corrects; the ranker takes the cheapest row of a store's newest capture, so whenever the old
# bug UNDERSTATED the price (5 of the 6 bad r300 rows) the wrong row kept the board cell forever.
$prefix = 'walmart-regular'
if (-not (Test-Path $regDir)) { New-Item -ItemType Directory -Path $regDir -Force | Out-Null }
$prev = Get-ChildItem (Join-Path $regDir ($prefix + '-*.json')) -EA SilentlyContinue | Where-Object { $_.BaseName -match ('^' + $prefix + '-\d{4}-\d{2}-\d{2}$') } | Sort-Object Name -Descending | Select-Object -First 1
function Get-RowKey($r) { if ($r.PSObject.Properties['item_id'] -and $r.item_id) { return ('id:' + $r.item_id) } return ('nm:' + (([string]$r.item).ToLower())) }
$merged = New-Object System.Collections.ArrayList; $idx = @{}; $doc = $null
if ($prev) {
  $doc = Get-Content $prev.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($r in @($doc.deals)) { $k = Get-RowKey $r; if (-not $idx.ContainsKey($k)) { $idx[$k] = $merged.Count }; [void]$merged.Add($r) }
}
$added = 0; $replaced = 0
foreach ($r in $rows) {
  $k = Get-RowKey $r
  if ($idx.ContainsKey($k)) { $merged[$idx[$k]] = $r; $replaced++ } else { $idx[$k] = $merged.Count; [void]$merged.Add($r); $added++ }
}
$outFile = Join-Path $regDir ($prefix + "-$today.json")
# file-level writer provenance: the copied header still says "built by build-walmart-deals.ps1, every row
# verified" - batch_imports makes the second writer visible so a divergence is traceable in the file itself.
$stamp = [pscustomobject]@{ date = $today; raw = $Raw; added = $added; replaced = $replaced; quarantined = $quarantined.Count; rejected = $rejects.Count; by = 'import-walmart-batch.ps1' }
if ($doc) {
  $doc.deals = $merged.ToArray()
  if ($doc.PSObject.Properties['deal_count']) { $doc.deal_count = $merged.Count } else { $doc | Add-Member deal_count $merged.Count -Force }
  if ($doc.PSObject.Properties['batch_imports']) { $doc.batch_imports = @(@($doc.batch_imports) + $stamp) } else { $doc | Add-Member batch_imports @($stamp) -Force }
  ($doc | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8
} else {
  ([ordered]@{ store = 'Walmart'; week_of = $today; price_type = 'everyday'; price_mode = 'in-store'; deal_count = $merged.Count; batch_imports = @($stamp); deals = $merged.ToArray() } | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8
}
if ($rejects.Count) { ($rejects | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $outRootDir ("out\walmart-batch-rejects-$today.json")) -Encoding UTF8 }
if ($quarantined.Count) {
  $qf = Join-Path $outRootDir ("out\walmart-batch-needs-seller-$today.json")
  ($quarantined | ConvertTo-Json -Depth 4) | Set-Content $qf -Encoding UTF8
  Write-Warning ("Walmart: {0} row(s) QUARANTINED (no seller/fulfillment field - marketplace filter could not run). Worklist: {1}. Re-capture with the 6-field reducer, or hand-verify and re-run with -TrustNoSeller." -f $quarantined.Count, $qf)
}
$idsDir = Join-Path $outRootDir 'out\staples500'
if (-not (Test-Path $idsDir)) { New-Item -ItemType Directory -Path $idsDir -Force | Out-Null }
($ids | ConvertTo-Json) | Set-Content (Join-Path $idsDir 'walmart-itemids.json') -Encoding UTF8
Write-Output ("Walmart: verified $($rows.Count) row(s) through the builder invariants ($added added, $replaced replaced, $($rejects.Count) rejected, $($quarantined.Count) quarantined), total $($merged.Count); name->itemId map: $($ids.Count) -> $(Split-Path $outFile -Leaf)")
