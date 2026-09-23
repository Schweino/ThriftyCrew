<#
  derive-links-from-prices.ps1 - THE LINK IS NOT A SEPARATE FACT. IT IS PART OF THE PRICE.

  Brad, correctly: "We cannot have our system fetch a price but not have a link. That doesn't make sense."

  He is right, and the whole wrong-link bug class comes from the architecture being built the other way:

      PRICES  come from out\regular\<store>-regular-<date>.json, fetched from a specific product.
      LINKS   come from product-urls.json, resolved LATER by SEARCHING the store for that product again.

  Two independent pipelines for one fact. They can always disagree, and they did: the board published
  "Hy Vee Almondmilk Original Unsweetened" while its link opened "Blue Diamond Almond Breeze"; storage-bags was
  crowned CHEAPEST advertising Ziploc 105ct at $0.04/each while its link opened That's Smart 12ct at $0.099
  (138% off). Nobody wrote those bugs. They are what a second pipeline does.

  The pullers ALREADY hold the identity - they fetched the price FROM a product that had an id and a URL - and
  then threw it away. So the fix is not a better search. It is to stop searching: carry the id with the price
  and DERIVE the link from the same row the board priced. A price and its link then cannot drift apart, because
  they are one record.

  This reads each store's regular file and writes product-urls entries for every board cell whose price row
  carries an identity. Derived links need no verification pass to trust - they are, by construction, the
  product the price came from - but prune-bad-links still checks them, because a claim that something cannot
  break is exactly the claim worth testing.

  Identity per store (what the row must carry):
    Hy-Vee       product_id      -> /aisles-online/p/<id>/<slug>
    Family Fare  canonical_url   -> used verbatim (NEVER construct a Freshop URL; that is how 4 dead links
                                    nearly shipped - the real shape is shopfamilyfare.com/shop/<cat>/<slug>/p/<id>)
    Walmart      item_id         -> /ip/<id>
    Sam's Club   item_id         -> /ip/<id>
    Baker's      link_url        -> used verbatim (stamped by the price pull)
    any store    link_url        -> used verbatim (the browser capture's third field)

  Read-only unless -Apply.
#>
# -Store scopes the derivation to one store. Added 2026-07-29 after a global -Apply re-pointed ~40 FAREWAY
# links onto pack prices where the board holds per-unit (24x, 100x, 120x factor mismatches on the publish
# gate) while fixing the Sam's links it was actually run for. When only one store's prices moved, only that
# store's links should move: a link layer this wide should never be rewritten wholesale to fix one store.
# -ProductUrlsFile is pinnable for the reason audit-tile-integrity's is: the live path is read from $root,
# so without it the ONLY way to exercise the write rules below is to edit the real link layer. Defaults to
# the live file, so every production caller is unchanged.
# -Commodity scopes it further to one commodity id (2026-09-22): add-known-wrong.ps1 calls it with -Store and
# -Commodity right after a ruling, so the one link that pointed at the newly ruled product is dropped or
# re-derived in the SAME run instead of waiting for tomorrow's chain (or for audit-known-wrong to hold a push).
# -KnownWrongFile is pinnable for the self-test; it defaults to the live known-wrong.json beside this script.
# -CommoditiesFile is pinnable for the self-test (2026-09-22, queue 2026-09-22-e9aed3); it defaults to the live
# commodities.json beside this script, with recipe-commodities.json added when it sits beside that file.
param([switch]$Apply, [string]$OutDir = "", [string]$Store = "", [string]$Commodity = "", [string]$ProductUrlsFile = "",
  [string]$KnownWrongFile = "", [string]$CommoditiesFile = "", [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path $PSScriptRoot 'regular-fileset-lib.ps1')
$UNION_DAYS = Get-RegularUnionDays
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $KnownWrongFile) { $KnownWrongFile = Join-Path $root 'known-wrong.json' }
. (Join-Path $root 'pu-lib.ps1')   # store what you audit: every entry re-prices through the same lib prune uses
. (Join-Path $root 'known-wrong-lib.ps1')   # THE ruling matcher (KwNorm/KwCore) compare-deals and audit-known-wrong use
. (Join-Path $root 'global-exclude-lib.ps1')
. (Join-Path $root 'commodity-rules-lib.ps1')   # Add-TcRuleIndex / Get-TcReleasingPattern: an exclude releases a linked product
if (-not $CommoditiesFile) { $CommoditiesFile = Join-Path $root 'commodities.json' }

# ---- SAM'S ALPHANUMERIC /ip/<id> IS PROVEN BY A FILE, NOT BY THIS SCRIPT (2026-09-22, plan-2026-09-22-10 bec597) ----
# Sam's moved every sams_item_id to an alphanumeric form (2,802 of 2,802 rows). The numeric /ip/<id> shape was
# proven in Brad's browser on 2026-07-17; the alphanumeric one had no proof, so 67 Sam's cells could never be
# re-linked and their PRICE-DRIFT only grew. The proof now lives in out\sams\sams-url-shape-<date>.json, written by
# the Sam's browser pass (pull-browser-stores.py opens /ip/<id> for 3 of the day's ids and reads the page's own id
# and name). Only the NEWEST file counts, and only a clean 3 of 3: 2 of 3, a wall ('blocked'), a parse failure or no
# file at all leave the alphanumeric id refused exactly as before. A proof that goes stale (the store changes its
# URL scheme) is caught the next morning, because the next pass re-proves it and a failed proof un-proves it.
function Test-SamsAlnumShapeProven([string]$Dir) {
  $f = Get-ChildItem (Join-Path $Dir 'sams\sams-url-shape-*.json') -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match '^sams-url-shape-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $f) { return @{ proven = $false; why = 'no sams-url-shape file' } }
  $d = $null
  try { $d = Read-JsonFile $f.FullName } catch { return @{ proven = $false; why = ($f.Name + ' does not parse') } }
  $cases = @($d.cases | Where-Object { $_ })
  $allMatch = ($cases.Count -eq 3) -and (@($cases | Where-Object { $_.match -eq $true -and $_.blocked -ne $true }).Count -eq 3)
  $ok = ([string]$d.verdict -eq 'proven') -and ([int]$d.proven -eq 3) -and ([int]$d.checked -eq 3) -and $allMatch
  $why = ($f.Name + ': verdict ' + [string]$d.verdict + ', ' + [string]$d.proven + ' of ' + [string]$d.checked)
  return @{ proven = $ok; why = $why }
}
$script:SamsShape = Test-SamsAlnumShapeProven $OutDir

# ---- price helpers, shared by the staleness test and the write rule -----------------------------------
function Get-PriceNumber([string]$text) {
  if (-not $text) { return 0.0 }
  $n = 0.0
  [void][double]::TryParse(($text -replace '[^0-9.]', ''), [ref]$n)
  return $n
}
# THE URL IS THE IDENTITY, THE PRICE IS THE FACT, AND ONLY THE IDENTITY WAS EVER COMPARED (2026-09-20).
# Graded exactly as audit-tile-integrity grades it - same pu-lib, same 2% / half-cent bar, everyday cells
# only, because those are the only ones that audit holds to price equality.
function Test-EntryStale($Entry, $Cell, [string]$Unit) {
  if (-not $Entry) { return $true }
  if (([string]$Cell.type) -ne 'everyday') { return $false }
  $bpu = [double]$Cell.per_unit
  if ($bpu -le 0) { return $false }
  $sp = Get-PriceNumber ([string]$Entry.price)
  if ($sp -le 0) { return $true }                       # nothing comparable stored: refresh it
  $lpu = Get-LinkPerUnit -size ([string]$Entry.size) -unit $Unit -price $sp -name ([string]$Entry.name)
  if ($null -eq $lpu -or $lpu -le 0) { return $true }
  return (([math]::Abs($lpu - $bpu) / $lpu) -gt 0.02 -and [math]::Abs($lpu - $bpu) -gt 0.005)
}

if ($SelfTest) {
  # FROZEN FIXTURES, out of process, on a temp tree named per run (never a fixed %TEMP% name - concurrent
  # pushes run this suite over each other). The two MUST FIRE rows are the real 2026-09-20 board rows that
  # blocked a gated coverage batch; the CLEAN TWIN is the churn-avoidance this script has always had.
  # 2026-09-22 (plan-2026-09-22-10): five more runs of the same child over the same frozen tree. Three drive the
  # Sam's url-shape proof (3 of 3 proven, 2 of 3, blocked) and one drives the known-wrong link re-check with the
  # real founding row, Fareway's fresh-tomatoes link to "Dei Fratelli Tomatoes, Whole".
  $bad = 0; $ran = 0
  function TT([string]$n, [bool]$ok, [string]$got) {
    $script:ran++
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $fx = Join-Path $env:TEMP ('dlfp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  [void](New-Item -ItemType Directory -Path $fx -Force -ErrorAction Stop)
  try {
    [void](New-Item -ItemType Directory -Path (Join-Path $fx 'regular') -Force -ErrorAction Stop)
    [void](New-Item -ItemType Directory -Path (Join-Path $fx 'sams') -Force -ErrorAction Stop)
    $cmpFx = @{ comparison = @(
        @{ id = 'feminine-pads'; unit = 'each'; stores = @(
            @{ store = 'Fareway'; per_unit = 0.2081; unit = 'each'; type = 'everyday'; item = 'Always Ultra Thin Pads with Wings'; ad = '$7.49'; size = '36 ct' },
            @{ store = "Sam's Club"; per_unit = 0.1683; unit = 'each'; type = 'everyday'; item = 'Always Ultra Thin Long Super Pads with Wings, Size 2, 92 ct.'; ad = '$15.48'; size = '92 ct' }) },
        @{ id = 'paper-towels'; unit = 'each'; stores = @(
            @{ store = 'Fareway'; per_unit = 1.0; unit = 'each'; type = 'everyday'; item = 'Frozen Twin Paper Towels'; ad = '$6.00'; size = '6 ct' }) },
        @{ id = 'trash-bags'; unit = 'each'; stores = @(
            @{ store = "Sam's Club"; per_unit = 0.2; unit = 'each'; type = 'everyday'; item = "Member's Mark Kitchen Bags 90 ct"; ad = '$18.00'; size = '90 ct' }) },
        @{ id = 'tomatoes'; unit = 'lb'; stores = @(
            @{ store = 'Fareway'; per_unit = 1.99; unit = 'lb'; type = 'sale'; item = 'Roma Tomatoes'; ad = '$1.99'; size = '1 lb' }) }) }
    ($cmpFx | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $fx 'comparison-2026-09-20.json') -Encoding UTF8
    # Fareway: the sale ($6.99) expired, the board published the row's own posted everyday price ($7.49).
    $fwFx = @{ deals = @(
        @{ item = 'Always Ultra Thin Pads with Wings'; ad_price = '$6.99'; regular = '$7.49'; size = '36 ct'; link_url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/34669-always-ultra-thin-pads-size-1-regular-with-wings-36-ct' },
        @{ item = 'Frozen Twin Paper Towels'; ad_price = '$6.00'; regular = '$6.00'; size = '6 ct'; link_url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/1-frozen-twin' },
        @{ item = 'Roma Tomatoes'; ad_price = '$1.99'; regular = '$2.49'; size = '1 lb'; link_url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/2-roma-tomatoes' }) }
    ($fwFx | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $fx 'regular\fareway-regular-2026-09-20.json') -Encoding UTF8
    # Sam's: the row the board priced carries an ALPHANUMERIC id no proven URL shape accepts, so the index
    # falls back to the older numeric-id row - whose price is two months stale. That substitution is what
    # stamped "DERIVED from the price row (same record the board priced)" onto a record from another month.
    $smFx = @{ deals = @(
        @{ item = 'Always Ultra Thin Long Super Pads with Wings, Size 2, 92 ct.'; ad_price = '$15.48'; regular = $null; size = '92 ct'; sams_item_id = '4YKF09SXNTK8' },
        @{ item = 'Always Ultra Thin Long Super Pads with Wings, Size 2, 92 ct.'; ad_price = '$12.48'; regular = $null; size = '92 ct'; sams_item_id = '15235818162' },
        @{ item = "Member's Mark Kitchen Bags 90 ct"; ad_price = '$18.00'; regular = $null; size = '90 ct'; sams_item_id = '15235818162' }) }
    ($smFx | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $fx 'regular\sams-regular-2026-09-19.json') -Encoding UTF8
    $puFx = Join-Path $fx 'product-urls.json'
    $kwNone = Join-Path $fx 'known-wrong-absent.json'   # never written: the pre-2026-09-22 runs read no ruling
    $cmNone = Join-Path $fx 'commodities-absent.json'   # never written: the arms before the rule-released case read no commodity rule
    $puSeed = @{ items = @{
        'feminine-pads' = @{
          'Fareway'     = @{ url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/34669-always-ultra-thin-pads-size-1-regular-with-wings-36-ct'; name = 'Always Ultra Thin Pads with Wings'; price = '6.99'; size = '36 ct' }
          "Sam's Club"  = @{ url = 'https://www.samsclub.com/ip/15235818162'; name = 'Always Ultra Thin Long Super Pads with Wings, Size 2, 92 ct.'; price = '$12.48'; size = '92 ct'; verified = '2026-09-19 DERIVED from the price row (same record the board priced)' }
        }
        'paper-towels' = @{
          'Fareway' = @{ url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/1-frozen-twin'; name = 'Frozen Twin Paper Towels'; price = '$6.00'; size = '6 ct'; verified = '2026-09-01 DERIVED from the price row (same record the board priced)' }
        }
        'tomatoes' = @{
          # THE FOUNDING ROW: derived on 2026-09-21 from the sale cell, hours before the product was ruled wrong.
          'Fareway' = @{ url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/9-dei-fratelli-whole'; name = 'Dei Fratelli Tomatoes, Whole'; price = '$2.68'; size = '28 oz'; verified = '2026-09-21 DERIVED from the price row (same record the board priced)' }
          'Hy-Vee'  = @{ url = 'https://www.hy-vee.com/aisles-online/p/1/tomatoes-on-the-vine'; name = 'Tomatoes on the Vine'; price = '$2.49'; size = '1 lb'; verified = '2026-09-10 DERIVED from the price row (same record the board priced)' }
        } } }
    $seedJson = ($puSeed | ConvertTo-Json -Depth 8)
    $seedJson | Set-Content -LiteralPath $puFx -Encoding UTF8
    $twinBefore = (Get-FileHash -LiteralPath $puFx -Algorithm SHA256).Hash
    $out = & powershell -NoProfile -File $PSCommandPath -OutDir $fx -ProductUrlsFile $puFx -KnownWrongFile $kwNone -CommoditiesFile $cmNone -Apply
    $rc = $LASTEXITCODE
    $text = ($out -join "`n")
    $after = Read-JsonFile $puFx
    $fw = $after.items.'feminine-pads'.'Fareway'
    $sm = $after.items.'feminine-pads'.PSObject.Properties["Sam's Club"]
    $tw = $after.items.'paper-towels'.'Fareway'
    $tb = $after.items.PSObject.Properties['trash-bags']

    TT 'the run completes and exits 0' ($rc -eq 0) ("rc=$rc")
    # MUST FIRE 1: a stored snapshot the board has outgrown is REFRESHED, not skipped as "already correct".
    TT 'MUST FIRE: Fareway pads snapshot is refreshed to the price the board published ($7.49)' `
      ((Get-PriceNumber ([string]$fw.price)) -eq 7.49) ("price=" + [string]$fw.price)
    TT 'MUST FIRE: the refreshed Fareway entry now re-prices to the cell (no PRICE-DRIFT left)' `
      (-not (Test-EntryStale -Entry $fw -Cell ([pscustomobject]@{ type = 'everyday'; per_unit = 0.2081 }) -Unit 'each')) ([string]$fw.price + ' / ' + [string]$fw.size)
    # MUST FIRE 2: a row that did not observe the board's price may not lend its URL to that cell.
    TT 'MUST FIRE: Sams entry is NOT rewritten from a row that never observed the board price 15.48' `
      ($null -ne $sm -and (Get-PriceNumber ([string]$sm.Value.price)) -eq 12.48) ("entry=" + $(if ($sm) { [string]$sm.Value.price } else { '<gone>' }))
    TT "MUST FIRE: the refusal is COUNTED and named, not silent" `
      ($text -match 'board price not observed' -and $text -match "Sam's Club") ($text -split "`n" | Select-String 'board price' | Select-Object -Last 1)
    # CLEAN TWIN: an entry that still agrees is still skipped and left byte-identical - the churn this
    # script has always avoided must survive the new staleness test.
    TT 'CLEAN TWIN: an entry that still prices to its cell is left untouched and counted already-correct' `
      (([string]$tw.verified) -eq '2026-09-01 DERIVED from the price row (same record the board priced)' -and $text -match 'already correct\s+:\s*1') `
      ([string]$tw.verified)
    TT 'CLEAN TWIN: the seeded file is not rewritten wholesale (only the drifted entry moved)' `
      ($twinBefore -ne (Get-FileHash -LiteralPath $puFx -Algorithm SHA256).Hash -and ([string]$tw.price) -eq '$6.00') ([string]$tw.price)
    TT "CLEAN TWIN: with NO url-shape file a numeric Sam's id still derives /ip/15235818162" `
      ($null -ne $tb -and ([string]$tb.Value.'Sam''s Club'.url) -eq 'https://www.samsclub.com/ip/15235818162') ($(if ($tb) { [string]$tb.Value.'Sam''s Club'.url } else { '<none>' }))
    TT "CLEAN TWIN: with NO url-shape file the run says the alphanumeric shape is not proven" `
      ($text -match "alphanumeric /ip/<id> shape: not proven \(no sams-url-shape file\)") ($text -split "`n" | Select-String 'shape:' | Select-Object -Last 1)

    # ---- the Sam's url-shape proof, three arms over the same seed (plan-2026-09-22-10, item 2026-09-20-bec597) ----
    function Write-ShapeFx([string]$verdict, [int]$proven, [bool[]]$match, [bool]$blocked) {
      $cs = @()
      $ids = @('1BWLUGF7QXGI', '1DAB9GS32WHT', '7H05KHCUZJ61')
      for ($i = 0; $i -lt $match.Count; $i++) { $cs += @{ sams_item_id = $ids[$i]; match = $match[$i]; blocked = ($blocked -and $i -eq ($match.Count - 1)) } }
      $doc = @{ date = '2026-09-22'; verdict = $verdict; proven = $proven; checked = $match.Count; cases = $cs }
      ($doc | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $fx 'sams\sams-url-shape-2026-09-22.json') -Encoding UTF8
    }
    function Invoke-ShapeArm {
      $seedJson | Set-Content -LiteralPath $puFx -Encoding UTF8
      $o = & powershell -NoProfile -File $PSCommandPath -OutDir $fx -ProductUrlsFile $puFx -KnownWrongFile $kwNone -CommoditiesFile $cmNone -Apply
      return @{ rc = $LASTEXITCODE; text = ($o -join "`n"); doc = (Read-JsonFile $puFx) }
    }
    Write-ShapeFx 'proven' 3 @($true, $true, $true) $false
    $a3 = Invoke-ShapeArm
    $sm3 = $a3.doc.items.'feminine-pads'.'Sam''s Club'
    TT "MUST FIRE: with a 3 of 3 url-shape file the alphanumeric row '4YKF09SXNTK8' derives /ip/4YKF09SXNTK8 at the board price 15.48" `
      ($a3.rc -eq 0 -and ([string]$sm3.url) -eq 'https://www.samsclub.com/ip/4YKF09SXNTK8' -and (Get-PriceNumber ([string]$sm3.price)) -eq 15.48) ("rc=" + $a3.rc + " url=" + [string]$sm3.url + " price=" + [string]$sm3.price)
    TT "CLEAN TWIN: with a 3 of 3 url-shape file the numeric id still derives /ip/15235818162" `
      (([string]$a3.doc.items.'trash-bags'.'Sam''s Club'.url) -eq 'https://www.samsclub.com/ip/15235818162') ([string]$a3.doc.items.'trash-bags'.'Sam''s Club'.url)
    Write-ShapeFx 'unproven' 2 @($true, $true, $false) $false
    $a2 = Invoke-ShapeArm
    TT "MUST NOT FIRE: a 2 of 3 url-shape file leaves the alphanumeric row refused exactly as before (entry stays 12.48 on /ip/15235818162)" `
      ($a2.rc -eq 0 -and ([string]$a2.doc.items.'feminine-pads'.'Sam''s Club'.url) -eq 'https://www.samsclub.com/ip/15235818162' -and (Get-PriceNumber ([string]$a2.doc.items.'feminine-pads'.'Sam''s Club'.price)) -eq 12.48) ([string]$a2.doc.items.'feminine-pads'.'Sam''s Club'.url)
    Write-ShapeFx 'blocked' 2 @($true, $true, $false) $true
    $ab = Invoke-ShapeArm
    TT "MUST NOT FIRE: a 'blocked' url-shape file (a wall on the third page) leaves the alphanumeric row refused" `
      ($ab.rc -eq 0 -and ([string]$ab.doc.items.'feminine-pads'.'Sam''s Club'.url) -eq 'https://www.samsclub.com/ip/15235818162' -and $ab.text -match 'shape: not proven') ([string]$ab.doc.items.'feminine-pads'.'Sam''s Club'.url)
    Remove-Item -LiteralPath (Join-Path $fx 'sams\sams-url-shape-2026-09-22.json') -Force

    # ---- a new ruling re-checks every link that points at its product (plan-2026-09-22-10, the tomatoes class) ----
    $kwFx = Join-Path $fx 'known-wrong.json'
    $kwDoc = @{ entries = @(@{ key = 'tomatoes|Fareway|dei-fratelli-tomatoes-whole'; commodity = 'tomatoes'; store = 'Fareway'; names = @('Dei Fratelli Tomatoes, Whole'); verdict = 'wrong-product'; ruled_on = '2026-09-21' }) }
    ($kwDoc | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $kwFx -Encoding UTF8
    $seedJson | Set-Content -LiteralPath $puFx -Encoding UTF8
    $ok = & powershell -NoProfile -File $PSCommandPath -OutDir $fx -ProductUrlsFile $puFx -KnownWrongFile $kwFx -CommoditiesFile $cmNone -Store 'Fareway' -Commodity 'tomatoes' -Apply
    $krc = $LASTEXITCODE; $ktext = ($ok -join "`n")
    $kdoc = Read-JsonFile $puFx
    $tf = $kdoc.items.'tomatoes'.'Fareway'
    TT "MUST FIRE: the Fareway tomatoes link to the newly ruled 'Dei Fratelli Tomatoes, Whole' is dropped in the same run" `
      ($krc -eq 0 -and ([string]$tf.name) -ne 'Dei Fratelli Tomatoes, Whole' -and $ktext -match 'links DROPPED, product ruled wrong: 1') ("rc=$krc name=" + [string]$tf.name)
    TT "MUST FIRE: the dropped link is RE-DERIVED from the row the board now prices (Roma Tomatoes), not left empty" `
      (([string]$tf.url) -eq 'https://shop.fareway.com/store/fareway-meat-grocery/products/2-roma-tomatoes') ([string]$tf.url)
    TT "CLEAN TWIN: the Hy-Vee tomatoes link, which the ruling does not name, is untouched" `
      (([string]$kdoc.items.'tomatoes'.'Hy-Vee'.verified) -eq '2026-09-10 DERIVED from the price row (same record the board priced)' -and ([string]$kdoc.items.'tomatoes'.'Hy-Vee'.name) -eq 'Tomatoes on the Vine') ([string]$kdoc.items.'tomatoes'.'Hy-Vee'.name)
    TT "CLEAN TWIN: -Commodity scopes the run, so the drifted Fareway pads link outside it is NOT refreshed" `
      ((Get-PriceNumber ([string]$kdoc.items.'feminine-pads'.'Fareway'.price)) -eq 6.99) ([string]$kdoc.items.'feminine-pads'.'Fareway'.price)
    # MUST FIRE, THE EXACT FOUNDING SHAPE: the ruled product's CELL IS GONE (the fixture board has no Hy-Vee tomatoes
    # cell), so nothing would ever re-derive over the link and no priced-tile audit would visit it. It must go.
    $kwDoc3 = @{ entries = @(@{ key = 'tomatoes|Hy-Vee|otv'; commodity = 'tomatoes'; store = 'Hy-Vee'; names = @('Tomatoes on the Vine'); verdict = 'wrong-product'; ruled_on = '2026-09-22' }) }
    ($kwDoc3 | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $kwFx -Encoding UTF8
    $seedJson | Set-Content -LiteralPath $puFx -Encoding UTF8
    $o3 = & powershell -NoProfile -File $PSCommandPath -OutDir $fx -ProductUrlsFile $puFx -KnownWrongFile $kwFx -CommoditiesFile $cmNone -Store 'Hy-Vee' -Commodity 'tomatoes' -Apply
    $k3 = Read-JsonFile $puFx
    TT "MUST FIRE: a ruled link whose cell is GONE from the board (the 2026-09-21 shape) is removed, not left for an audit to find" `
      ($LASTEXITCODE -eq 0 -and $null -eq $k3.items.'tomatoes'.PSObject.Properties['Hy-Vee'] -and $null -ne $k3.items.'tomatoes'.PSObject.Properties['Fareway']) ((($o3 -join "`n") -split "`n" | Select-String 'DROPPED' | Select-Object -Last 1))
    # MUST FIRE: a board row whose OWN name is ruled wrong never lends its URL (the ruling written before the rebuild).
    $kwDoc2 = @{ entries = @(@{ key = 'tomatoes|Fareway|roma'; commodity = 'tomatoes'; store = 'Fareway'; names = @('Roma Tomatoes'); verdict = 'wrong-product'; ruled_on = '2026-09-22' }) }
    ($kwDoc2 | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $kwFx -Encoding UTF8
    $seedJson | Set-Content -LiteralPath $puFx -Encoding UTF8
    $o2 = & powershell -NoProfile -File $PSCommandPath -OutDir $fx -ProductUrlsFile $puFx -KnownWrongFile $kwFx -CommoditiesFile $cmNone -Store 'Fareway' -Commodity 'tomatoes' -Apply
    $k2 = Read-JsonFile $puFx
    TT "MUST FIRE: a priced row whose own name is ruled wrong is refused and counted, and no link is written from it" `
      ((($o2 -join "`n") -match 'rows refused, product ruled wrong: 1') -and ([string]$k2.items.'tomatoes'.'Fareway'.url) -ne 'https://shop.fareway.com/store/fareway-meat-grocery/products/2-roma-tomatoes') ([string]$k2.items.'tomatoes'.'Fareway'.url)

    # ---- AN EXCLUDE RELEASES A LINKED PRODUCT (2026-09-22, queue 2026-09-22-e9aed3, the chorizo founding row) ----
    # Its own tree, so the arms above are untouched. The real rows: mexican-chorizo-fresh gained `\bbeef\b`, the
    # Walmart cell moved to "Cacique Pork Chorizo, 9 oz (Refrigerated)" (item 11027816, $1.50, 0.56 lb), and the
    # link stayed on walmart.com/ip/10451933 "Cacique Beef Chorizo 12oz". A Hy-Vee link to a beef chorizo with NO
    # Hy-Vee cell is the shape only the rule drop can reach: no derivation will ever write over it.
    $cz = Join-Path $fx 'chz'
    [void](New-Item -ItemType Directory -Path (Join-Path $cz 'regular') -Force -ErrorAction Stop)
    (@{ comparison = @(@{ id = 'mexican-chorizo-fresh'; unit = 'lb'; stores = @(
            @{ store = 'Walmart'; per_unit = 2.6786; unit = 'lb'; type = 'everyday'; item = 'Cacique Pork Chorizo, 9 oz (Refrigerated)'; ad = '$1.50'; size = '0.56 lb' },
            @{ store = "Baker's"; per_unit = 3.5467; unit = 'lb'; type = 'everyday'; item = 'Kroger Mercado Chorizo Sausage Pork Links'; ad = '$3.99'; size = '5 pk 3.6 oz' }) }) } |
      ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $cz 'comparison-2026-09-22.json') -Encoding UTF8
    (@{ deals = @(@{ item = 'Cacique Pork Chorizo, 9 oz (Refrigerated)'; ad_price = '$1.50'; regular = $null; size = '0.56 lb'; item_id = '11027816' }) } |
      ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $cz ('regular\walmart-regular-' + (Get-Date -Format 'yyyy-MM-dd') + '.json')) -Encoding UTF8
    $czCm = Join-Path $cz 'commodities.json'
    ConvertTo-Json -Depth 5 -InputObject @(@{ id = 'mexican-chorizo-fresh'; unit = 'lb'; include = @('\bchorizo\b'); exclude = @('\b(?:spanish|cured|smoked)\b', '\bbeef\b') }) |
      Set-Content -LiteralPath $czCm -Encoding UTF8
    $czPu = Join-Path $cz 'product-urls.json'
    (@{ items = @{ 'mexican-chorizo-fresh' = @{
          'Walmart' = @{ url = 'https://www.walmart.com/ip/10451933'; name = 'Cacique Beef Chorizo 12oz'; price = '1.5'; size = '0.75 lb'; verified = '2026-08-31 price-pull self-capture' }
          'Hy-Vee'  = @{ url = 'https://www.hy-vee.com/aisles-online/p/9/beef-chorizo'; name = 'Hy-Vee Beef Chorizo'; price = '$3.49'; size = '1 lb'; verified = '2026-09-10 DERIVED from the price row (same record the board priced)' }
          "Baker's" = @{ url = 'https://www.bakersplus.com/p/kroger-mercado-chorizo-sausage-pork-links/0001111062555'; name = 'Kroger Mercado Chorizo Sausage Pork Links'; price = '$3.99'; size = '5 pk 3.6 oz'; verified = '2026-09-20 DERIVED from the price row (same record the board priced)' } } } } |
      ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $czPu -Encoding UTF8
    $oc = & powershell -NoProfile -File $PSCommandPath -OutDir $cz -ProductUrlsFile $czPu -KnownWrongFile $kwNone -CommoditiesFile $czCm -Commodity 'mexican-chorizo-fresh' -Apply
    $crc = $LASTEXITCODE; $ctext = ($oc -join "`n"); $cdoc = Read-JsonFile $czPu
    $cItems = $cdoc.items.'mexican-chorizo-fresh'
    TT "MUST FIRE: the Walmart chorizo link to the beef product the new \bbeef\b exclude released is dropped and RE-DERIVED from item 11027816" `
      ($crc -eq 0 -and $ctext -match 'released by its commodity rule: 2' -and ([string]$cItems.'Walmart'.url) -eq 'https://www.walmart.com/ip/11027816' -and ([string]$cItems.'Walmart'.name) -eq 'Cacique Pork Chorizo, 9 oz (Refrigerated)') ("rc=$crc url=" + [string]$cItems.'Walmart'.url)
    TT "MUST FIRE: a released link whose store has NO cell (Hy-Vee Beef Chorizo) is removed, not left for nothing to visit" `
      ($null -eq $cItems.PSObject.Properties['Hy-Vee']) ($(if ($cItems.PSObject.Properties['Hy-Vee']) { [string]$cItems.'Hy-Vee'.name } else { '<gone>' }))
    TT "CLEAN TWIN: the Baker's pork links link, which the exclude does not refuse, keeps its url and its verified stamp" `
      (([string]$cItems."Baker's".url) -eq 'https://www.bakersplus.com/p/kroger-mercado-chorizo-sausage-pork-links/0001111062555' -and ([string]$cItems."Baker's".verified) -eq '2026-09-20 DERIVED from the price row (same record the board priced)') ([string]$cItems."Baker's".verified)
  }
  finally { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Output ''
  if ($bad -eq 0 -and $ran -eq 22) { Write-Output ('derive-links-from-prices self-test: PASS (' + $ran + ' case(s), 0 failure(s))'); exit 0 }
  Write-Output ("derive-links-from-prices self-test: FAIL (" + $bad + " failure(s) of " + $ran + " case(s) run, 22 expected)")
  exit 1
}

$STORES = @(
  @{ store = 'Hy-Vee'; glob = 'hyvee-regular-*.json' }
  @{ store = 'Family Fare'; glob = 'family-fare-regular-*.json' }
  @{ store = 'Walmart'; glob = 'walmart-regular-*.json' }
  @{ store = "Sam's Club"; glob = 'sams-regular-*.json' }
  @{ store = "Baker's"; glob = 'bakers-regular-*.json' }
  @{ store = 'Aldi'; glob = 'aldi-regular-*.json' }
  @{ store = 'Fareway'; glob = 'fareway-regular-*.json' }
)
if ($Store) {
  $STORES = @($STORES | Where-Object { $_.store -eq $Store })
  if ($STORES.Count -eq 0) { throw ("derive-links-from-prices: unknown -Store '$Store'") }
  Write-Output ("scoped to $Store only - no other store's links will be touched")
}

# The board is NOT priced from out\regular\ alone: compare-deals also ingests out\bakers\bakers-deals-*.json,
# out\fareway\fareway-deals-*.json, and EVERY out\sams\sams-deals-*.json inside a 14-day window (Sam's is
# captured in CAPTCHA-walled partial slices, so one file never covers the catalog). When this script indexed
# only out\regular\, every cell priced from those files read as "no matching row" and its identity was thrown
# away - 1,296 fresh Sam's rows carrying sams_item_id produced zero links. That is the two-pipeline bug this
# script exists to kill, one level down. Index the SAME files the engine priced from.
#   Order = price authority: for Sam's the deals captures ARE the primary source (its regular file is a
#   29-row vestige), newest capture first; elsewhere regular leads and deal files fill gaps.
#   First writer wins per name|size key, so a fresher capture's row beats an older one.
function Get-StoreFiles([string]$store) {
  $reg = Get-ChildItem (Join-Path $OutDir ('regular\' + (($STORES | Where-Object { $_.store -eq $store }).glob))) -EA SilentlyContinue |
    Where-Object { $_.BaseName -match '-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Desc | Select-Object -First 1
  $files = @()
  switch ($store) {
    "Sam's Club" {
      foreach ($f in (Get-ChildItem (Join-Path $OutDir 'sams\sams-deals-*.json') -EA SilentlyContinue | Sort-Object Name -Descending)) {
        if ($f.BaseName -notmatch '(\d{4}-\d{2}-\d{2})$') { continue }
        # $UNION_DAYS, not 14: the engine unions Sam's captures over the SAME window, so a private copy
        # here silently refuses to derive links for cells the board is actively pricing.
        if ([math]::Abs(([datetime]$Matches[1] - (Get-Date)).TotalDays) -gt $UNION_DAYS) { continue }
        $files += $f.FullName
      }
      if ($reg) { $files += $reg.FullName }
    }
    "Baker's" {
      if ($reg) { $files += $reg.FullName }
      $f = Get-ChildItem (Join-Path $OutDir 'bakers\bakers-deals-*.json') -EA SilentlyContinue | Sort-Object Name -Desc | Select-Object -First 1
      if ($f) { $files += $f.FullName }
    }
    'Fareway' {
      if ($reg) { $files += $reg.FullName }
      $f = Get-ChildItem (Join-Path $OutDir 'fareway\fareway-deals-*.json') -EA SilentlyContinue | Sort-Object Name -Desc | Select-Object -First 1
      if ($f) { $files += $f.FullName }
    }
    'Walmart' {
      # THE SAME TWO-PIPELINE BUG AS SAM'S, one store later (2026-08-30, queue loose-end-e). Walmart's
      # board is a UNION too: compare-deals ingests every walmart-regular-*.json inside the union window
      # because the daily rotation only re-prices a couple of dozen terms, so most Walmart cells are
      # priced from an older comprehensive capture. Indexing only the newest file left 485 of Walmart's
      # priced cells reading as "board cell has no matching row" - their identity was on disk the whole
      # time and thrown away, so relink-drifted-cells could REPORT their drift forever and never repair
      # it. That is how the frozen-fruit Walmart chip sat pointing at Great Value Cherry Berry Blend
      # while the cell priced Great Value Whole Strawberries: reported daily, repairable never.
      # Newest first, because first writer wins per name|size key - a fresher capture's row beats an
      # older one, and the write-time re-pricing check still refuses any row whose per-unit disagrees
      # with the board by more than the pruner's tolerance.
      foreach ($f in (Get-ChildItem (Join-Path $OutDir 'regular\walmart-regular-*.json') -EA SilentlyContinue |
          Where-Object { $_.BaseName -match '-(\d{4}-\d{2}-\d{2})$' } | Sort-Object Name -Descending)) {
        if ($f.BaseName -notmatch '(\d{4}-\d{2}-\d{2})$') { continue }
        if ([math]::Abs(([datetime]$Matches[1] - (Get-Date)).TotalDays) -gt $UNION_DAYS) { continue }
        $files += $f.FullName
      }
    }
    default { if ($reg) { $files += $reg.FullName } }
  }
  return $files
}

function Get-RowUrl($store, $r) {
  # A URL the row already holds always wins - it was observed, not built.
  if ($r.link_url -and ([string]$r.link_url) -match '^https?://') { return [string]$r.link_url }
  if ($r.canonical_url -and ([string]$r.canonical_url) -match '^https?://') { return [string]$r.canonical_url }
  # Otherwise build one ONLY from an id whose URL shape is proven for that store.
  switch ($store) {
    'Hy-Vee' {
      if ($r.product_id -and ([string]$r.product_id) -match '^\d+$') {
        $slug = ((([string]$r.item).ToLower() -replace '[^a-z0-9]+', '-').Trim('-'))
        if ($slug.Length -gt 80) { $slug = $slug.Substring(0, 80).TrimEnd('-') }
        return ('https://www.hy-vee.com/aisles-online/p/' + [string]$r.product_id + '/' + $slug)
      }
    }
    'Walmart' { if ($r.item_id -and ([string]$r.item_id) -match '^\d+$') { return ('https://www.walmart.com/ip/' + [string]$r.item_id) } }
    "Sam's Club" {
      # the quarantine-recovery rows stamp the id as sams_item_id; older rows used item_id. Accept both.
      # Bare /ip/<id> is PROVEN (2026-07-17, Brad's browser): Sam's 301s it to the canonical /ip/<slug>/<id>
      # and renders the exact product; a bogus id renders an "Uh-oh" page, so the shape cannot silently lie.
      $sid = if ($r.sams_item_id) { [string]$r.sams_item_id } elseif ($r.item_id) { [string]$r.item_id } else { '' }
      if ($sid -match '^\d+$') { return ('https://www.samsclub.com/ip/' + $sid) }
      if ($script:SamsShape.proven -and $sid -match '^[A-Za-z0-9]{6,20}$') { return ('https://www.samsclub.com/ip/' + $sid) }
    }
  }
  return $null
}

$cmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1
$cmp = (Read-JsonFile $cmpF.FullName).comparison
$puPath = if ($ProductUrlsFile) { $ProductUrlsFile } else { Join-Path $root 'product-urls.json' }
$puDoc = Read-JsonFile $puPath
if ($Commodity) {
  $cmp = @($cmp | Where-Object { [string]$_.id -eq $Commodity })
  Write-Output ("scoped to commodity $Commodity only (" + $cmp.Count + " board row) - no other commodity's links will be touched")
}

# ---- A RULING RE-CHECKS EVERY LINK THAT POINTS AT ITS PRODUCT (2026-09-22, plan-2026-09-22-10) ----------------
# The founding case: on 2026-09-21 this script derived Fareway's fresh-tomatoes link from the row that priced a new
# sale cell, "Dei Fratelli Tomatoes, Whole" - a 28 oz CAN. Hours later that product was ruled wrong in
# known-wrong.json. The ruling corrected the BOARD at the next compare-deals, but nothing re-checked the LINK: the
# cell it described was gone, so neither the staleness test below (it only visits priced cells) nor the pruner
# (it only grades priced tiles) ever looked at it again, and the next thing to see it was audit-known-wrong holding
# a push. A ruling is one fact with two copies (the cell and its link), so both are corrected where the ruling is
# applied: every link whose stored product name the ruling matches (the SAME KwNorm/KwCore test compare-deals and
# audit-known-wrong use) is dropped here, before derivation, and the derivation below then re-derives that cell's
# link from the row the board now prices, in the same run, when that row carries an identity. A row whose name is
# itself ruled wrong never lends its URL either.
# AN EXCLUDE IS A RULING TOO (2026-09-22, queue 2026-09-22-e9aed3). A commodity exclude releases a product exactly
# as a known-wrong ruling does, one level up: mexican-chorizo-fresh gained `\bbeef\b`, its Walmart cell moved to
# Cacique PORK Chorizo, and the link kept opening "Cacique Beef Chorizo 12oz" because nothing re-checked it. So the
# same drop covers a link whose stored name its own commodity's effective excludes refuse, and the derivation below
# re-derives the cell from the row the board now prices. Every caller that applies an exclude runs this script
# scoped to the commodities it touched (apply-coverage-batch, audit-match-soundness -Accept).
$ruleIx = @{}
if (Test-Path -LiteralPath $CommoditiesFile) {
  Add-TcRuleIndex -Index $ruleIx -Doc (Read-JsonFile $CommoditiesFile)
  $rcF = Join-Path (Split-Path -Parent $CommoditiesFile) 'recipe-commodities.json'
  if (Test-Path -LiteralPath $rcF) { Add-TcRuleIndex -Index $ruleIx -Doc (Read-JsonFile $rcF) }
}
$ruleDropped = New-Object System.Collections.Generic.List[string]
if ($ruleIx.Count -gt 0 -and $puDoc.items) {
  foreach ($cProp in @($puDoc.items.PSObject.Properties)) {
    if ($Commodity -and $cProp.Name -ne $Commodity) { continue }
    if ($cProp.Value -isnot [psobject]) { continue }
    foreach ($sProp in @($cProp.Value.PSObject.Properties)) {
      if ($Store -and $sProp.Name -ne $Store) { continue }
      $ev = $sProp.Value
      if ($ev -isnot [psobject] -or -not $ev.PSObject.Properties['name']) { continue }
      $relP = Get-TcReleasingPattern -Index $ruleIx -Id $cProp.Name -Name ([string]$ev.name)
      if ($relP) {
        $ruleDropped.Add(('  {0,-13}{1,-24}{2}   (exclude {3})' -f $sProp.Name, $cProp.Name, [string]$ev.name, $relP))
        $cProp.Value.PSObject.Properties.Remove($sProp.Name)
      }
    }
  }
}

$kwBlocks = Get-KnownWrongBlocks -Path $KnownWrongFile
$kwDropped = New-Object System.Collections.Generic.List[string]
if ($kwBlocks.Count -gt 0 -and $puDoc.items) {
  foreach ($cProp in @($puDoc.items.PSObject.Properties)) {
    if ($Commodity -and $cProp.Name -ne $Commodity) { continue }
    if ($cProp.Value -isnot [psobject]) { continue }
    foreach ($sProp in @($cProp.Value.PSObject.Properties)) {
      if ($Store -and $sProp.Name -ne $Store) { continue }
      $ev = $sProp.Value
      if ($ev -isnot [psobject] -or -not $ev.PSObject.Properties['name']) { continue }
      if (Test-KnownWrong -Blocks $kwBlocks -CommodityId $cProp.Name -Store $sProp.Name -ProductName ([string]$ev.name)) {
        $kwDropped.Add(('  {0,-13}{1,-24}{2}' -f $sProp.Name, $cProp.Name, [string]$ev.name))
        $cProp.Value.PSObject.Properties.Remove($sProp.Name)
      }
    }
  }
}

# index each store's rows by name+SIZE. Never by name alone: stores sell one name in several sizes, and a
# name-keyed map silently keeps the last - the bug family this repo has now hit six times.
$rowsByStore = @{}
foreach ($sp in $STORES) {
  $ix = @{}
  foreach ($file in (Get-StoreFiles $sp.store)) {
    foreach ($r in @((Read-JsonFile $file).deals)) {
      $key = (([string]$r.item).Trim() + '|' + ([string]$r.size).Trim())
      # duplicate name+size = same product; keep the copy that can actually be linked. A row carrying
      # identity beats one that doesn't; among carriers the freshest file (listed first) wins.
      $have = $ix[$key]
      if (-not $have) { $ix[$key] = $r }
      elseif (-not (Get-RowUrl $sp.store $have)) { if (Get-RowUrl $sp.store $r) { $ix[$key] = $r } }
    }
  }
  if ($ix.Count) { $rowsByStore[$sp.store] = $ix }
}

$derived = 0; $already = 0; $noIdentity = @{}; $rowMissing = 0; $unwritable = 0; $unproven = @{}; $kwRowRefused = 0
$changes = New-Object System.Collections.Generic.List[string]
foreach ($row in $cmp) {
  $id = [string]$row.id
  foreach ($s in $row.stores) {
    $store = [string]$s.store
    if ([double]$s.per_unit -le 0) { continue }              # not a priced tile
    if (-not $rowsByStore.ContainsKey($store)) { continue }
    $key = (([string]$s.item).Trim() + '|' + ([string]$s.size).Trim())
    $r = $rowsByStore[$store][$key]
    if (-not $r) { $rowMissing++; continue }                  # board cell not traceable to a row (ad-only)
    if (Test-KnownWrong -Blocks $kwBlocks -CommodityId $id -Store $store -ProductName ([string]$r.item)) { $kwRowRefused++; continue }
    $url = Get-RowUrl $store $r
    if (-not $url) {
      if (-not $noIdentity.ContainsKey($store)) { $noIdentity[$store] = 0 }
      $noIdentity[$store]++
      continue
    }
    $cur = $puDoc.items.$id.$store
    # "SAME URL, THEREFORE ALREADY CORRECT" IS HOW A SNAPSHOT OUTLIVES THE PRICE IT RECORDED (2026-09-20).
    # The url is the identity; the price is the fact, and only the identity was being compared. A store
    # reprices the SAME product page, or a sale expires and the board falls back to the row's own posted
    # regular price, and this script skipped the entry forever because the url had not moved -
    # audit-tile-integrity then reported PRICE-DRIFT on a link derive-links believed it had already fixed.
    # 225 of those on the 2026-09-20 board, and 2 of them blocked a gated coverage batch. So `already` now
    # means what it says: same url AND a stored snapshot that still re-prices to the cell it is attached to.
    if ($cur -and ([string]$cur.url) -eq $url -and -not (Test-EntryStale -Entry $cur -Cell $s -Unit ([string]$row.unit))) { $already++; continue }
    # DERIVE FROM THE SAME RECORD THE BOARD PRICED - WHICH MEANS THE SAME PRICE FIELD, TOO (2026-09-20).
    # A row carries more than one observed price: ad_price (what it sells for) and regular (the store's own
    # posted everyday price). The board publishes whichever the policy chose, so when a sale expires the cell
    # falls back to `regular` while this script kept writing `ad_price` - the link record was born disagreeing
    # with the tile it describes. The entry now records the price the BOARD PUBLISHED, and only after proving
    # that number is one THIS ROW actually observed. If it is neither, this row is not the record that priced
    # the cell (a 2026-07-29 Sam's row at $12.48 standing in for the 2026-09-19 one at $15.48, because the
    # fresh row's id is alphanumeric and no proven URL shape accepts it) and no link is written at all.
    # Taking the board's number on trust instead would launder the disagreement into the record - which is a
    # price nobody observed on that page, and this estate does not write one of those.
    $entryPrice = [string]$r.ad_price
    if (([string]$s.type) -eq 'everyday') {
      $bp = Get-PriceNumber ([string]$s.ad)
      $proven = ''
      foreach ($cand in @([string]$r.ad_price, [string]$r.regular)) {
        if (-not $cand) { continue }
        $cn = Get-PriceNumber $cand
        if ($cn -gt 0 -and $bp -gt 0 -and [math]::Abs($cn - $bp) -le 0.005) { $proven = $cand; break }
      }
      if (-not $proven) {
        if (-not $unproven.ContainsKey($store)) { $unproven[$store] = 0 }
        $unproven[$store]++
        continue
      }
      $entryPrice = $proven
      # STORE WHAT YOU AUDIT. Before writing, re-price the entry exactly as tomorrow's pruner will. An entry
      # the pruner cannot compute a per-unit for would be written today and deleted tomorrow - churn that
      # reads as link flapping. Refuse it here and count it, so the gap is visible instead of laundered.
      $sp = Get-PriceNumber $entryPrice
      $lpu = Get-LinkPerUnit -size ([string]$r.size) -unit ([string]$row.unit) -price $sp -name ([string]$r.item)
      $bpu = [double]$s.per_unit
      if ($null -eq $lpu -or ($bpu -gt 0 -and ([math]::Abs($lpu - $bpu) / $bpu -gt 0.32) -and ([math]::Abs($lpu - $bpu) -gt 0.005))) {
        $unwritable++
        continue
      }
    }
    $changes.Add(('  {0,-13}{1,-24}{2}' -f $store, $id, ([string]$s.item)))
    $derived++
    if ($Apply) {
      if (-not $puDoc.items.$id) { $puDoc.items | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]@{}) }
      $entry = [pscustomobject]@{
        url      = $url
        name     = [string]$r.item
        price    = $entryPrice
        size     = [string]$r.size
        verified = ((Get-Date -Format 'yyyy-MM-dd') + ' DERIVED from the price row (same record the board priced)')
      }
      $puDoc.items.$id | Add-Member -NotePropertyName $store -NotePropertyValue $entry -Force
    }
  }
}

Write-Output ("links DROPPED, product ruled wrong: " + $kwDropped.Count + "  (known-wrong.json rules the linked product wrong for that commodity and store)")
foreach ($c in ($kwDropped | Select-Object -First 15)) { Write-Output $c }
Write-Output ("links DROPPED, product released by its commodity rule: " + $ruleDropped.Count + "  (the link names a product the commodity's own excludes refuse)")
foreach ($c in ($ruleDropped | Select-Object -First 40)) { Write-Output $c }
Write-Output ("rows refused, product ruled wrong: " + $kwRowRefused)
Write-Output ("Sam's alphanumeric /ip/<id> shape: " + $(if ($script:SamsShape.proven) { 'PROVEN' } else { 'not proven' }) + " (" + $script:SamsShape.why + ")")
Write-Output ("links DERIVED from the price row : " + $derived)
foreach ($c in ($changes | Select-Object -First 15)) { Write-Output $c }
if ($changes.Count -gt 15) { Write-Output ('  ... and ' + ($changes.Count - 15) + ' more') }
Write-Output ("already correct                  : " + $already)
Write-Output ("refused at write time            : " + $unwritable + "  (the pruner could not verify these; writing them would be churn)")
Write-Output ("board cell has no matching row   : " + $rowMissing + "  (ad-only cells - the ad is the source; there is no product page)")
# THE STANDING CHECK FOR AN UNANNOUNCED SOURCE CHANGE. A field whose SHAPE moves (Sam's sams_item_id going
# alphanumeric on 2,802 of 2,802 rows) keeps its name and its null rate, so only an assertion sees it - and
# the assertion here used to fail SILENTLY by taking an older row's identity instead. Named, per store.
$unprovenTotal = 0
foreach ($k in $unproven.Keys) { $unprovenTotal += $unproven[$k] }
Write-Output ("board price not observed on the row: " + $unprovenTotal + "  (the row that carries a linkable identity never saw the price the board published, so it is not the record that priced the cell - NO link written)")
foreach ($k in ($unproven.Keys | Sort-Object)) { Write-Output ('  ' + $k.PadRight(14) + $unproven[$k]) }
Write-Output ''
Write-Output 'priced rows carrying NO product identity (these CANNOT be linked - the puller/capture dropped it):'
foreach ($k in ($noIdentity.Keys | Sort-Object)) { Write-Output ('  ' + $k.PadRight(14) + $noIdentity[$k]) }
if ($Apply) {
  ($puDoc | ConvertTo-Json -Depth 8) | Set-Content $puPath -Encoding UTF8
  Write-Output ''
  Write-Output ("APPLIED: " + $derived + " link(s) written from the rows the board priced.")
}
else { Write-Output ''; Write-Output 'DRY RUN. Pass -Apply to write.' }
exit 0
