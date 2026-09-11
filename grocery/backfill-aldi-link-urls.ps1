<#
  backfill-aldi-link-urls.ps1 - ONE-OFF REPAIR (2026-09-11). Put back the product links build-aldi-regular dropped
  from 2026-08-25 to 2026-09-10, on the rows that still carry that window's prices.

  WHAT BROKE. The committed search agent (aldiSearchExtract in pull-aldi-instore.js) writes RELATIVE hrefs,
  /store/aldi/products/<id>-<slug>, and Invoke-Build kept an href only when it matched ^https?://, so every row
  built in that window shipped with no link_url. 04727f04c fixed the BUILDER (Resolve-AldiProductUrl), and new
  builds link again. But carry-forward-regular.ps1 copies older rows forward unchanged, so a row first captured in
  the window stays unlinked until its found_by_term is re-searched, which under the quarterly rotation is up to 90
  days. An unlinked row gives derive-links-from-prices nothing to derive from (Get-RowUrl wants an absolute
  link_url for Aldi), and it loses the has_identity tie-break in compare-deals' Select-StoreWinner.

  MEASURED 2026-09-11, before this was written, on aldi-regular-2026-09-10.json at 04727f04c (3,288 rows) against
  comparison-2026-09-09.json (built 2026-09-11 08:11; 572 commodities, 371 with an Aldi cell):
      rows with as_of 2026-08-25..2026-09-10     2,178 of 3,288
      of those, carrying no link_url             2,178 of 2,178
      Aldi cells held by one of them             260 of 371 (exact item+size), and Aldi is cheapest overall in 75
  Aldi cells held by an unlinked row of ANY date: 304 of the 366 that resolve to a row in that file.

  DRY RUN 2026-09-11, same file and board, captures read from the main checkout, through this file as first
  committed on top of 04727f04c (one variant, no re-runs to choose between):
      MATCHED 2,108 of 2,178 (96.8%); NO-EXACT-MATCH 65, AMBIGUOUS 5, every other verdict 0; 15 of 15 captures read
      the matched rows hold 259 of the 260 affected Aldi board cells
      cross-check outside the join: 2,106 of 2,108 stamped links carry a URL slug equal to the row's item name
      (letters and digits only); the other 2 are the builder's own slug-decimal repairs, 0.75 oz from -75-oz and
      15.5 oz from -155oz-155-oz. No link was stamped on two rows.
      The 65 are multipack and liquid rows that today's builder sizes differently from the build that wrote them
      (card multiplication, 2026-09-09), which is exactly the shape this join exists to leave alone.

  THE JOIN, AND WHY IT IS THIS NARROW
    - A row is joined ONLY to the capture of its OWN as_of date, aldi-capture-<as_of>.csv. The .csv and never the
      .txt twin: on 2026-09-04 the .txt lacks the column header, so it is not the file that build read (the other
      .txt twins in the window are byte-identical to their .csv).
    - That capture is rebuilt through build-aldi-regular.ps1 ITSELF, dot-sourced - Read-AldiCapture, then
      Invoke-Build - so every name and size here is produced by the builder and none by this file.
    - ONE RECORD AT A TIME. Invoke-Build keeps only the first of two records that name the same item and size, and
      a backfill has to SEE the second one to know the pair is ambiguous.
    - A link is stamped only when the rebuilt item AND size equal the row's (ordinal), the rebuilt price equals the
      row's current_price, and every record meeting both carries ONE link. A name never stamps anything alone,
      and neither does a name and a size at a different price.
    - The builder's naming rules moved inside the window (slug decimals 2026-08-28, card multiplication
      2026-09-09). A record today's builder names differently from that morning's build does not match, and is
      left unlinked and COUNTED under NO-EXACT-MATCH. So MATCHED is a floor on what was recoverable, not a ceiling.
    - Every capture in the window predates the #tc-store line (2026-09-10), which the builder's reader refuses.
      -WaiveMissingStoreLine waives that one refusal for this re-read. Any other store refusal still stands.

  VERDICTS, one per window row, every one written to the case file (one row per case):
    MATCH               stamped on -Apply; would be, on a dry run
    NO-CAPTURE          there is no aldi-capture-<as_of>.csv
    CAPTURE-REFUSED     the capture names a store the builder refuses
    NO-EXACT-MATCH      no rebuilt record has this item and this size
    PRICE-DISAGREES     item and size agree, and no such record has this price
    NO-LINK-IN-CAPTURE  the agreeing record(s) carried no readable aldi.us product href
    AMBIGUOUS           the agreeing records carry more than one link

  Usage:  .\backfill-aldi-link-urls.ps1 -CaptureDir <dir> [-Board <comparison.json>]     DRY RUN, the default
          .\backfill-aldi-link-urls.ps1 -CaptureDir <dir> -Apply
          .\backfill-aldi-link-urls.ps1 -SelfTest
    -Regular     the aldi-regular file. Default: the newest in out\regular, the one carry-forward copies from.
    -CaptureDir  default out\captures. The captures are GITIGNORED, so a worktree has none: point this at the main
                 checkout's grocery\out\captures (it is only read) or seed with ops\seed-worktree.ps1.
    -Board       optional. Also reports how many Aldi cells the window rows and the matched rows hold.
    -Report      the per-case .jsonl. Default: %TEMP% on a dry run, out\audit\ on -Apply.
  -Apply writes through a temp copy, reads the copy back, and replaces the file only when the copy is the original
  plus exactly the stamped links. It REFUSES a file that does not round-trip through ConvertTo-Json -Depth 6, the
  serializer build-aldi-regular and carry-forward-regular write it with, because a rewrite would then move bytes
  this repair does not own.
  Exit 0 = ran (a dry run, or applied and read back). 1 = self-test failure, or -Apply refused or failed its
  read-back, with the file untouched. 3 = COULD NOT EVALUATE: no regular file, no capture directory, or window
  rows with not one capture resolved. Never read 3 as nothing to do.
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param(
  [string]$Regular = '',
  [string]$CaptureDir = '',
  [string]$Board = '',
  [string]$Report = '',
  [string]$From = '2026-08-25',
  [string]$To = '2026-09-10',
  [switch]$DryRun,
  [switch]$Apply,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$opt = @{ Regular = $Regular; CaptureDir = $CaptureDir; Board = $Board; Report = $Report; From = $From; To = $To
          DryRun = [bool]$DryRun; Apply = [bool]$Apply; SelfTest = [bool]$SelfTest }
. (Join-Path (Split-Path $here -Parent) 'lib\json-io.ps1')
# THE BUILDER, DOT-SOURCED: its own functions, never a copy. Dot-sourcing runs its param() block in THIS scope and
# resets $SelfTest, $In and $Date, which is why every parameter above was saved into $opt first and -SelfTest is put
# back on the next line. Do not name a variable here $In, $Date or $root: the builder owns those.
. (Join-Path $here 'build-aldi-regular.ps1')
$SelfTest = [switch]$opt.SelfTest

$VERDICTS = @('MATCH', 'NO-CAPTURE', 'CAPTURE-REFUSED', 'NO-EXACT-MATCH', 'PRICE-DISAGREES', 'NO-LINK-IN-CAPTURE', 'AMBIGUOUS')

function Test-IsoDate([string]$s) { return ($s -cmatch '^\d{4}-\d{2}-\d{2}$') }

function Get-RebuiltCaptureIndex {
  <# Rebuild one capture through the builder, one record at a time, and index every priced result by its exact
     item|size. Returns data and prints nothing (Import-CaptureCsv's rule, for the same reason). #>
  param([string]$Path, [string]$AsOf)
  $cap = Read-AldiCapture -Path $Path -Date $AsOf -WaiveMissingStoreLine
  if ($cap.refuse) { return @{ refuse = $cap.refuse; records = 0; priced = 0; index = $null } }
  $index = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
  $records = 0; $priced = 0
  foreach ($rec in $cap.raw) {
    $records++
    $b = Invoke-Build @($rec) $AsOf
    if ($b.rows.Count -ne 1) { continue }
    $priced++
    $r = $b.rows[0]
    $k = [string]$r.item + '|' + [string]$r.size
    if (-not $index.ContainsKey($k)) { $index[$k] = New-Object System.Collections.ArrayList }
    $lk = if ($r.PSObject.Properties['link_url']) { [string]$r.link_url } else { '' }
    [void]$index[$k].Add([pscustomobject]@{ price = [double]$r.current_price; link = $lk })
  }
  return @{ refuse = ''; records = $records; priced = $priced; index = $index }
}

function Resolve-RowLink {
  <# Pure. One window row against the rebuilt index of its OWN as_of capture. #>
  param($Row, $Index)
  $k = [string]$Row.item + '|' + [string]$Row.size
  if (-not $Index.ContainsKey($k)) { return @{ verdict = 'NO-EXACT-MATCH'; link = ''; detail = 'no rebuilt record has this item and size' } }
  $cands = $Index[$k]
  $want = [double]$Row.current_price
  $links = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $agree = 0; $hrefless = 0
  foreach ($c in $cands) {
    if ([math]::Abs($c.price - $want) -gt 0.0001) { continue }
    $agree++
    if ($c.link) { [void]$links.Add($c.link) } else { $hrefless++ }
  }
  if ($agree -eq 0) { return @{ verdict = 'PRICE-DISAGREES'; link = ''; detail = ('{0} record(s) share item and size, none priced {1}' -f $cands.Count, $want) } }
  if ($links.Count -eq 0) { return @{ verdict = 'NO-LINK-IN-CAPTURE'; link = ''; detail = ('{0} agreeing record(s), none with a readable product href' -f $agree) } }
  if ($links.Count -gt 1) { return @{ verdict = 'AMBIGUOUS'; link = ''; detail = ('{0} different links among {1} agreeing record(s)' -f $links.Count, $agree) } }
  $only = ''
  foreach ($l in $links) { $only = $l }
  return @{ verdict = 'MATCH'; link = $only; detail = ('{0} agreeing record(s), one link, {1} without a readable href' -f $agree, $hrefless) }
}

function ConvertTo-NormalText([string]$s) { return (($s -replace "`r`n", "`n").TrimEnd()) }

function Test-BackfillReadBack {
  <# '' when the file at AfterPath is the original text plus exactly the stamped links, otherwise the first
     difference found. Compares every row, and the envelope, field by field. #>
  param([string]$Before, [string]$AfterPath, $Cases)
  $orig = $Before | ConvertFrom-Json
  $after = Read-JsonFile $AfterPath
  $od = $orig.deals; $ad = $after.deals
  $on = @($od).Count; $an = @($ad).Count
  if ($on -ne $an) { return ('row count moved: {0} -> {1}' -f $on, $an) }
  $oe = $orig | Select-Object * -ExcludeProperty deals | ConvertTo-Json -Depth 4 -Compress
  $ae = $after | Select-Object * -ExcludeProperty deals | ConvertTo-Json -Depth 4 -Compress
  if (-not [string]::Equals($oe, $ae, [StringComparison]::Ordinal)) { return 'the file envelope changed' }
  $want = @{}
  foreach ($c in $Cases) { if ([string]::Equals($c.verdict, 'MATCH', [StringComparison]::Ordinal)) { $want[[int]$c.idx] = [string]$c.link_url } }
  for ($i = 0; $i -lt $on; $i++) {
    $o = $od[$i]; $a = $ad[$i]
    $oLink = if ($o.PSObject.Properties['link_url']) { [string]$o.link_url } else { '' }
    $aLink = if ($a.PSObject.Properties['link_url']) { [string]$a.link_url } else { '' }
    $expect = if ($want.ContainsKey($i)) { $want[$i] } else { $oLink }
    if (-not [string]::Equals($aLink, $expect, [StringComparison]::Ordinal)) { return ('row {0} [{1}]: link_url is [{2}], expected [{3}]' -f $i, $o.item, $aLink, $expect) }
    $oj = $o | Select-Object * -ExcludeProperty link_url | ConvertTo-Json -Depth 4 -Compress
    $aj = $a | Select-Object * -ExcludeProperty link_url | ConvertTo-Json -Depth 4 -Compress
    if (-not [string]::Equals($oj, $aj, [StringComparison]::Ordinal)) { return ('row {0} [{1}]: a field other than link_url changed' -f $i, $o.item) }
  }
  return ''
}

function Invoke-AldiLinkBackfill {
  <# The whole repair as data. Selects the window rows, rebuilds each as_of capture once, rules every row, and -
     only with -DoApply - writes the stamped file through a temp copy that must pass Test-BackfillReadBack first.
     Prints nothing; the caller reports. #>
  param([string]$RegularPath, [string]$CapDir, [string]$FromDate, [string]$ToDate, [switch]$DoApply)
  $text = Read-TextFile $RegularPath
  $doc = $text | ConvertFrom-Json
  # Serialized BEFORE anything is touched, so this is the question "would a rewrite move bytes we do not own".
  $reText = $doc | ConvertTo-Json -Depth 6
  $roundTrip = [string]::Equals((ConvertTo-NormalText $text), (ConvertTo-NormalText $reText), [StringComparison]::Ordinal)

  $deals = $doc.deals
  $rowCount = @($deals).Count
  $byDate = @{}
  $windowRows = 0; $alreadyLinked = 0; $i = -1
  foreach ($d in $deals) {
    $i++
    $asOf = if ($d.PSObject.Properties['as_of']) { [string]$d.as_of } else { '' }
    if (-not (Test-IsoDate $asOf)) { continue }
    if ([string]::CompareOrdinal($asOf, $FromDate) -lt 0 -or [string]::CompareOrdinal($asOf, $ToDate) -gt 0) { continue }
    $lk = if ($d.PSObject.Properties['link_url']) { [string]$d.link_url } else { '' }
    if ($lk) { $alreadyLinked++; continue }
    if (-not $byDate.ContainsKey($asOf)) { $byDate[$asOf] = New-Object System.Collections.ArrayList }
    [void]$byDate[$asOf].Add([pscustomobject]@{ idx = $i; row = $d })
    $windowRows++
  }

  $cases = New-Object System.Collections.ArrayList
  $dates = New-Object System.Collections.ArrayList
  $resolved = 0
  $sortedDates = $byDate.Keys | Sort-Object
  foreach ($asOf in @($sortedDates)) {
    $capPath = Join-Path $CapDir ('aldi-capture-' + $asOf + '.csv')
    $state = ''; $ix = $null
    if (-not (Test-Path -LiteralPath $capPath -PathType Leaf)) { $state = 'missing' }
    else {
      $ix = Get-RebuiltCaptureIndex -Path $capPath -AsOf $asOf
      if ($ix.refuse) { $state = 'refused' } else { $state = 'read'; $resolved++ }
    }
    $matched = 0
    foreach ($w in $byDate[$asOf]) {
      $d = $w.row
      if ($state -ceq 'missing') { $v = @{ verdict = 'NO-CAPTURE'; link = ''; detail = ('no ' + (Split-Path $capPath -Leaf)) } }
      elseif ($state -ceq 'refused') { $v = @{ verdict = 'CAPTURE-REFUSED'; link = ''; detail = $ix.refuse } }
      else { $v = Resolve-RowLink -Row $d -Index $ix.index }
      if ($v.verdict -ceq 'MATCH') { $matched++ }
      [void]$cases.Add([pscustomobject]@{ idx = $w.idx; as_of = $asOf; item = [string]$d.item; size = [string]$d.size
                                          current_price = $d.current_price; verdict = $v.verdict; link_url = $v.link; detail = $v.detail; row = $d })
    }
    $capNote = if ($state -ceq 'read') { ('{0} record(s) rebuilt, {1} priced' -f $ix.records, $ix.priced) } elseif ($state -ceq 'refused') { ('REFUSED: ' + $ix.refuse) } else { 'NO CAPTURE' }
    [void]$dates.Add([pscustomobject]@{ as_of = $asOf; rows = $byDate[$asOf].Count; matched = $matched; capture = $capNote })
  }

  $res = @{ refuse = ''; verifyFail = ''; wrote = $false; stamped = 0; roundTrip = $roundTrip; rows = $rowCount
            window = $windowRows; alreadyLinked = $alreadyLinked; resolved = $resolved; cases = $cases; dates = $dates }
  if (-not $DoApply) { return $res }

  if (-not $roundTrip) {
    $res.refuse = 'the file does not round-trip through ConvertTo-Json -Depth 6, the serializer its writers use, so a rewrite would move bytes this repair does not own. Nothing was written.'
    return $res
  }
  $stamped = 0
  foreach ($c in $cases) {
    if (-not ($c.verdict -ceq 'MATCH')) { continue }
    if ($c.row.PSObject.Properties['link_url']) { $c.row.link_url = $c.link_url }
    else { $c.row | Add-Member -NotePropertyName link_url -NotePropertyValue $c.link_url }
    $stamped++
  }
  $res.stamped = $stamped
  if ($stamped -eq 0) { return $res }
  $outText = $doc | ConvertTo-Json -Depth 6
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('aldi-link-backfill-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    Set-Content -Path $tmp -Value $outText -Encoding UTF8
    $bad = Test-BackfillReadBack -Before $text -AfterPath $tmp -Cases $cases
    if ($bad) { $res.verifyFail = $bad; return $res }
    Copy-Item -LiteralPath $tmp -Destination $RegularPath -Force
    $res.wrote = $true
  } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  return $res
}

function Write-BackfillCases {
  <# One JSON line per case, BOM-less so a line-by-line reader parses the first line too. #>
  param([string]$Path, $Cases)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $sb = New-Object Text.StringBuilder
  foreach ($c in $Cases) {
    $line = [pscustomobject]@{ as_of = $c.as_of; item = $c.item; size = $c.size; current_price = $c.current_price
                               verdict = $c.verdict; link_url = $c.link_url; detail = $c.detail } | ConvertTo-Json -Compress
    [void]$sb.Append($line).Append("`n")
  }
  [IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
}

if ($SelfTest) {
  $fail = 0
  $n = 0
  function BfT([string]$m, [bool]$c, [string]$got = '') {
    $script:n++
    if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + $(if ($got) { '   got: ' + $got } else { '' })); $script:fail++ }
  }
  $T = Join-Path ([IO.Path]::GetTempPath()) ('aldi-link-backfill-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    $capDirT = Join-Path $T 'captures'
    New-Item -ItemType Directory -Path $capDirT -Force | Out-Null
    $utf8 = New-Object Text.UTF8Encoding($false)
    $COLS = 'id|term|name|prices|unit|size|href'
    # FROZEN VERBATIM from aldi-capture-2026-09-10.csv line 2 and its row in aldi-regular-2026-09-10.json: the
    # founding shape, a relative href whose row shipped with no link_url.
    $DONUT = 'donuts|glazed donuts|bake shop assorted donut holes 14 oz|$2.69||14 oz|/store/aldi/products/28024425-bake-shop-assorted-donut-holes-14-oz'
    $cap = @{
      '2026-09-10' = @($COLS, $DONUT,
        'milk|milk gallon|friendly farms whole milk|$2.19||1 gal|/store/aldi/products/222-friendly-farms-whole-milk',
        'bacon|bacon|appleton farms thick sliced bacon|$3.49||16 oz|/store/aldi/products/333-appleton-farms-thick-sliced-bacon',
        'beans|black beans|dakota s pride black beans|$0.79||15 oz|/store/aldi/products/444-dakota-s-pride-black-beans',
        'beans|black beans|dakota s pride black beans|$0.79||15 oz|/store/aldi/products/555-dakota-s-pride-black-beans',
        'butter|butter|countryside creamery butter quarters|$3.19||16 oz|/store/aldi/products/666-countryside-creamery-butter-quarters',
        'pasta|pasta|reggano spaghetti|$0.95||16 oz|/store/aldi/products/1313-reggano-spaghetti')
      '2026-09-09' = @($COLS, 'eggs|eggs|goldhen grade a large eggs 12 ct|$1.65||12 ct|/store/aldi/products/111-goldhen-grade-a-large-eggs-12-ct')
      '2026-09-07' = @('#tc-store store="ALDI - OLA 12 - Lincoln" mode="In-Store" rows=1', $COLS,
        'oats|oats|millville old fashioned oats|$2.79||42 oz|/store/aldi/products/888-millville-old-fashioned-oats')
      '2026-09-06' = @('#tc-store store="ALDI - OLA 42 - Omaha" mode="In-Store" rows=1', $COLS,
        'rice|rice|earthly grains long grain white rice|$1.99||32 oz|/store/aldi/products/1212-earthly-grains-long-grain-white-rice')
      '2026-08-22' = @($COLS, 'cereal|cereal|millville crispy rice|$1.89||12 oz|/store/aldi/products/777-millville-crispy-rice')
    }
    foreach ($k in $cap.Keys) { [IO.File]::WriteAllText((Join-Path $capDirT ('aldi-capture-' + $k + '.csv')), ($cap[$k] -join "`n"), $utf8) }

    function New-FixtureRow([string]$item, [string]$size, [double]$price, [string]$asOf, [string]$link = '') {
      $h = [ordered]@{ store = 'Aldi'; item = $item; ad_price = ('$' + $price); size = $size; regular = $null; current_price = $price
                       source_ad = 'everyday shelf price'; price_type = 'everyday'; as_of = $asOf; found_by_term = 'x' }
      if ($link) { $h['link_url'] = $link }
      return [pscustomobject]$h
    }
    $rowsT = @(
      (New-FixtureRow 'Bake Shop Assorted Donut Holes 14 OZ' '14 oz' 2.69 '2026-09-10'),
      (New-FixtureRow 'Friendly Farms Whole Milk' '0.5 gal' 2.19 '2026-09-10'),
      (New-FixtureRow 'Appleton Farms Thick Sliced Bacon' '16 oz' 4.29 '2026-09-10'),
      (New-FixtureRow 'Dakota S Pride Black Beans' '15 oz' 0.79 '2026-09-10'),
      (New-FixtureRow 'Countryside Creamery Butter Quarters' '16 oz' 3.19 '2026-09-09'),
      (New-FixtureRow 'Simply Nature Organic Salsa' '16 oz' 2.49 '2026-09-08'),
      (New-FixtureRow 'Millville Old Fashioned Oats' '42 oz' 2.79 '2026-09-07'),
      (New-FixtureRow 'Earthly Grains Long Grain White Rice' '32 oz' 1.99 '2026-09-06'),
      (New-FixtureRow 'Millville Crispy Rice' '12 oz' 1.89 '2026-08-22'),
      (New-FixtureRow 'Reggano Spaghetti' '16 oz' 0.95 '2026-09-10' 'https://www.aldi.us/store/aldi/products/9999-reggano-spaghetti')
    )
    $docT = [ordered]@{ store = 'Aldi'; week_of = '2026-09-10'; price_type = 'everyday'; deal_count = $rowsT.Count; deals = $rowsT }
    $regT = Join-Path $T 'aldi-regular-2026-09-10.json'
    ($docT | ConvertTo-Json -Depth 6) | Set-Content $regT -Encoding UTF8   # the exact write build-aldi-regular makes
    $md5Before = (Get-FileHash -LiteralPath $regT -Algorithm MD5).Hash

    BfT 'CLEAN TWIN  the builder dot-sources without running its build, and its Invoke-Build is callable here' `
        ([bool](Get-Command Invoke-Build -CommandType Function -ErrorAction SilentlyContinue))

    $dry = Invoke-AldiLinkBackfill -RegularPath $regT -CapDir $capDirT -FromDate '2026-08-25' -ToDate '2026-09-10'
    $by = @{}
    foreach ($c in $dry.cases) { $by[$c.item] = $c }
    function VerdictOf([string]$item) { if ($by.ContainsKey($item)) { return [string]$by[$item].verdict } return '<not a case>' }

    BfT 'MUST FIRE  the founding shape: a window row rejoined to its own capture gets the resolved aldi.us link' `
        ((VerdictOf 'Bake Shop Assorted Donut Holes 14 OZ') -ceq 'MATCH' -and [string]::Equals([string]$by['Bake Shop Assorted Donut Holes 14 OZ'].link_url, 'https://www.aldi.us/store/aldi/products/28024425-bake-shop-assorted-donut-holes-14-oz', [StringComparison]::Ordinal)) `
        (VerdictOf 'Bake Shop Assorted Donut Holes 14 OZ')
    BfT 'MUST NOT FIRE  the name alone never stamps: same item, different size' `
        ((VerdictOf 'Friendly Farms Whole Milk') -ceq 'NO-EXACT-MATCH') (VerdictOf 'Friendly Farms Whole Milk')
    BfT 'MUST NOT FIRE  item and size agree at a different price' `
        ((VerdictOf 'Appleton Farms Thick Sliced Bacon') -ceq 'PRICE-DISAGREES') (VerdictOf 'Appleton Farms Thick Sliced Bacon')
    BfT 'MUST NOT FIRE  two agreeing records with different links stamp neither' `
        ((VerdictOf 'Dakota S Pride Black Beans') -ceq 'AMBIGUOUS') (VerdictOf 'Dakota S Pride Black Beans')
    BfT 'MUST NOT FIRE  a match in ANOTHER date''s capture never stamps: butter is in 09-10, the row is 09-09' `
        ((VerdictOf 'Countryside Creamery Butter Quarters') -ceq 'NO-EXACT-MATCH') (VerdictOf 'Countryside Creamery Butter Quarters')
    BfT 'MUST NOT FIRE  a row whose as_of has no capture gets NO-CAPTURE' `
        ((VerdictOf 'Simply Nature Organic Salsa') -ceq 'NO-CAPTURE') (VerdictOf 'Simply Nature Organic Salsa')
    BfT 'MUST FIRE  the waiver waives ONLY a missing store line: a Lincoln store line is still refused' `
        ((VerdictOf 'Millville Old Fashioned Oats') -ceq 'CAPTURE-REFUSED') (VerdictOf 'Millville Old Fashioned Oats')
    BfT 'CLEAN TWIN  a capture that DOES carry an Omaha In-Store store line still reads and matches' `
        ((VerdictOf 'Earthly Grains Long Grain White Rice') -ceq 'MATCH') (VerdictOf 'Earthly Grains Long Grain White Rice')
    BfT 'MUST NOT FIRE  a row dated before the window is not a case, though its own capture would match it' `
        ((VerdictOf 'Millville Crispy Rice') -ceq '<not a case>') (VerdictOf 'Millville Crispy Rice')
    BfT 'MUST NOT FIRE  a window row that already has a link is not a case' `
        ((VerdictOf 'Reggano Spaghetti') -ceq '<not a case>' -and $dry.alreadyLinked -eq 1) (VerdictOf 'Reggano Spaghetti')
    BfT 'CLEAN TWIN  the tally reads 2 matched of 8 window rows, over 5 dates of which 3 captures were read' `
        (@($dry.cases | Where-Object { $_.verdict -ceq 'MATCH' }).Count -eq 2 -and $dry.window -eq 8 -and $dry.dates.Count -eq 5 -and $dry.resolved -eq 3) `
        ('window={0} dates={1} resolved={2}' -f $dry.window, $dry.dates.Count, $dry.resolved)
    BfT 'CLEAN TWIN  a file written the way build-aldi-regular writes it round-trips' $dry.roundTrip
    BfT 'MUST NOT FIRE  a dry run leaves the regular file byte-identical' `
        ([string]::Equals((Get-FileHash -LiteralPath $regT -Algorithm MD5).Hash, $md5Before, [StringComparison]::Ordinal))

    # -Apply, on the same fixture
    $origText = Read-TextFile $regT
    $app = Invoke-AldiLinkBackfill -RegularPath $regT -CapDir $capDirT -FromDate '2026-08-25' -ToDate '2026-09-10' -DoApply
    $back = Read-JsonFile $regT
    $bl = @{}
    foreach ($r in $back.deals) { $bl[[string]$r.item] = $(if ($r.PSObject.Properties['link_url']) { [string]$r.link_url } else { '' }) }
    BfT 'CLEAN TWIN  -Apply stamps the two matched rows, and the read-back passed before the file was replaced' `
        ($app.wrote -and $app.stamped -eq 2 -and -not $app.verifyFail -and
         [string]::Equals($bl['Bake Shop Assorted Donut Holes 14 OZ'], 'https://www.aldi.us/store/aldi/products/28024425-bake-shop-assorted-donut-holes-14-oz', [StringComparison]::Ordinal) -and
         [string]::Equals($bl['Earthly Grains Long Grain White Rice'], 'https://www.aldi.us/store/aldi/products/1212-earthly-grains-long-grain-white-rice', [StringComparison]::Ordinal)) `
        ('wrote={0} stamped={1} verify=[{2}]' -f $app.wrote, $app.stamped, $app.verifyFail)
    BfT 'CLEAN TWIN  -Apply leaves the already-linked row''s own link exactly as it was' `
        ([string]::Equals($bl['Reggano Spaghetti'], 'https://www.aldi.us/store/aldi/products/9999-reggano-spaghetti', [StringComparison]::Ordinal)) $bl['Reggano Spaghetti']
    $unstamped = 0
    foreach ($k in @('Friendly Farms Whole Milk', 'Appleton Farms Thick Sliced Bacon', 'Dakota S Pride Black Beans', 'Countryside Creamery Butter Quarters',
                     'Simply Nature Organic Salsa', 'Millville Old Fashioned Oats', 'Millville Crispy Rice')) { if (-not $bl[$k]) { $unstamped++ } }
    BfT 'MUST NOT FIRE  -Apply links none of the seven rows that did not match, the pre-window row included' ($unstamped -eq 7) ('{0} of 7 still unlinked' -f $unstamped)
    BfT 'CLEAN TWIN  the read-back check passes the applied file against the original text' `
        (-not (Test-BackfillReadBack -Before $origText -AfterPath $regT -Cases $app.cases))

    # the verifier itself must catch a rewrite that moved something it does not own
    $tamper = Join-Path $T 'tampered.json'
    $tdoc = Read-JsonFile $regT
    foreach ($r in $tdoc.deals) { if ([string]::Equals([string]$r.item, 'Millville Crispy Rice', [StringComparison]::Ordinal)) { $r.current_price = 0.89 } }
    ($tdoc | ConvertTo-Json -Depth 6) | Set-Content $tamper -Encoding UTF8
    $tv = Test-BackfillReadBack -Before $origText -AfterPath $tamper -Cases $app.cases
    BfT 'MUST FIRE  the read-back refuses a rewrite that moved a price on a row it did not stamp' ($tv -match 'other than link_url') $tv

    # a second run finds nothing more to stamp and writes nothing
    $md5Applied = (Get-FileHash -LiteralPath $regT -Algorithm MD5).Hash
    $again = Invoke-AldiLinkBackfill -RegularPath $regT -CapDir $capDirT -FromDate '2026-08-25' -ToDate '2026-09-10' -DoApply
    BfT 'MUST NOT FIRE  a second -Apply stamps nothing and leaves the file byte-identical' `
        ($again.stamped -eq 0 -and -not $again.wrote -and $again.window -eq 6 -and [string]::Equals((Get-FileHash -LiteralPath $regT -Algorithm MD5).Hash, $md5Applied, [StringComparison]::Ordinal)) `
        ('stamped={0} window={1}' -f $again.stamped, $again.window)

    # a file its writers did not write is refused before anything is touched
    $flat = Join-Path $T 'aldi-regular-flat.json'
    [IO.File]::WriteAllText($flat, ($origText | ConvertFrom-Json | ConvertTo-Json -Depth 6 -Compress), $utf8)
    $md5Flat = (Get-FileHash -LiteralPath $flat -Algorithm MD5).Hash
    $rf = Invoke-AldiLinkBackfill -RegularPath $flat -CapDir $capDirT -FromDate '2026-08-25' -ToDate '2026-09-10' -DoApply
    BfT 'MUST FIRE  -Apply refuses a file that does not round-trip through its writers'' serializer, and leaves it untouched' `
        ($rf.refuse -match 'round-trip' -and -not $rf.wrote -and [string]::Equals((Get-FileHash -LiteralPath $flat -Algorithm MD5).Hash, $md5Flat, [StringComparison]::Ordinal)) $rf.refuse
  } finally { Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue }

  if ($fail) { Write-Output ("backfill-aldi-link-urls self-test: {0} of {1} FAILED" -f $fail, $n); exit 1 }
  Write-Output ("backfill-aldi-link-urls self-test: all {0} cases pass" -f $n)
  exit 0
}

# ------------------------------------------------------------------------------------------------------- the run
if ($opt.DryRun -and $opt.Apply) { throw 'backfill-aldi-link-urls: -DryRun and -Apply together - pick one' }
$doApply = $opt.Apply
$regDir = Join-Path $here 'out\regular'
$newestPath = ''
$regFiles = Get-ChildItem -Path $regDir -Filter 'aldi-regular-*.json' -File -ErrorAction SilentlyContinue |
  Where-Object { $_.BaseName -cmatch '^aldi-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name
foreach ($f in @($regFiles)) { if ($f) { $newestPath = $f.FullName } }
$regPath = if ($opt.Regular) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($opt.Regular) } else { $newestPath }
if (-not $regPath -or -not (Test-Path -LiteralPath $regPath -PathType Leaf)) {
  Write-Output ('backfill-aldi-link-urls: COULD NOT EVALUATE - no aldi-regular file ({0})' -f $(if ($regPath) { $regPath } else { 'none in ' + $regDir }))
  exit 3
}
$capDir = if ($opt.CaptureDir) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($opt.CaptureDir) } else { Join-Path $here 'out\captures' }
if (-not (Test-Path -LiteralPath $capDir -PathType Container)) {
  Write-Output ('backfill-aldi-link-urls: COULD NOT EVALUATE - no capture directory at {0}. The captures are gitignored, so a worktree has none: pass -CaptureDir at the main checkout''s grocery\out\captures (it is only read), or seed with ops\seed-worktree.ps1.' -f $capDir)
  exit 3
}
if (-not (Test-IsoDate $opt.From) -or -not (Test-IsoDate $opt.To)) { throw 'backfill-aldi-link-urls: -From and -To must be yyyy-MM-dd' }

$isNewest = [string]::Equals($regPath, $newestPath, [StringComparison]::OrdinalIgnoreCase)
$res = Invoke-AldiLinkBackfill -RegularPath $regPath -CapDir $capDir -FromDate $opt.From -ToDate $opt.To -DoApply:$doApply

$mode = if ($doApply) { 'APPLY' } else { 'DRY RUN - the regular file is not touched; -Apply stamps it' }
Write-Output ('backfill-aldi-link-urls: ' + $mode)
Write-Output ('  regular file : {0}  ({1} rows; the newest aldi-regular here: {2})' -f $regPath, $res.rows, $(if ($isNewest) { 'yes' } else { 'NO - carry-forward copies from the newest, so stamping this one reaches nothing' }))
Write-Output ('  captures     : {0}  (read only)' -f $capDir)
Write-Output ('  window       : as_of {0}..{1}: {2} row(s) with no link_url, {3} already linked' -f $opt.From, $opt.To, $res.window, $res.alreadyLinked)
Write-Output ('  as_of dates  : {0} carry window rows; a capture was read for {1} of {0}' -f $res.dates.Count, $res.resolved)
foreach ($dd in $res.dates) { Write-Output ('     {0}  rows {1,4}  matched {2,4}   {3}' -f $dd.as_of, $dd.rows, $dd.matched, $dd.capture) }
$matchedN = @($res.cases | Where-Object { $_.verdict -ceq 'MATCH' }).Count
$pct = if ($res.window) { 100.0 * $matchedN / $res.window } else { 0.0 }
Write-Output ('  MATCHED {0} of {1} window row(s) ({2:0.0}%)' -f $matchedN, $res.window, $pct)
foreach ($vv in $VERDICTS) {
  $cnt = @($res.cases | Where-Object { $_.verdict -ceq $vv }).Count
  Write-Output ('     {0,-19} {1,5} of {2}' -f $vv, $cnt, $res.window)
}
Write-Output ('  round trip   : the file {0} through ConvertTo-Json -Depth 6' -f $(if ($res.roundTrip) { 'round-trips byte-for-byte (line endings aside)' } else { 'does NOT round-trip - -Apply will refuse it' }))

if ($opt.Board) {
  $bdoc = Read-JsonFile $opt.Board
  $winKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $matchKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($c in $res.cases) {
    [void]$winKeys.Add($c.item + '|' + $c.size)
    if ($c.verdict -ceq 'MATCH') { [void]$matchKeys.Add($c.item + '|' + $c.size) }
  }
  $aldiCells = 0; $winCells = 0; $matchCells = 0; $matchCheapest = 0
  foreach ($cm in $bdoc.comparison) {
    foreach ($s in $cm.stores) {
      if (-not [string]::Equals([string]$s.store, 'Aldi', [StringComparison]::Ordinal)) { continue }
      $aldiCells++
      $bk = [string]$s.item + '|' + [string]$s.size
      if ($winKeys.Contains($bk)) { $winCells++ }
      if ($matchKeys.Contains($bk)) { $matchCells++; if ([string]::Equals([string]$cm.cheapest_store, 'Aldi', [StringComparison]::Ordinal)) { $matchCheapest++ } }
    }
  }
  Write-Output ('  board        : {0}' -f $opt.Board)
  Write-Output ('     Aldi cells held by a window row with no link : {0} of {1}' -f $winCells, $aldiCells)
  Write-Output ('     of those, held by a MATCHED row             : {0} of {1} (Aldi cheapest overall in {2})' -f $matchCells, $winCells, $matchCheapest)
}

$regDate = [regex]::Match((Split-Path $regPath -Leaf), '(\d{4}-\d{2}-\d{2})').Groups[1].Value
$reportPath = if ($opt.Report) { $opt.Report } elseif ($doApply) { Join-Path $here ('out\audit\aldi-link-backfill-' + $regDate + '.jsonl') } else { Join-Path ([IO.Path]::GetTempPath()) ('aldi-link-backfill-' + $regDate + '-dryrun.jsonl') }
Write-BackfillCases -Path $reportPath -Cases $res.cases
Write-Output ('  case file    : {0}  ({1} line(s), one per window row)' -f $reportPath, $res.cases.Count)

$code = 0
if ($doApply) {
  if ($res.refuse) { Write-Output ('  APPLY REFUSED: ' + $res.refuse); $code = 1 }
  elseif ($res.verifyFail) { Write-Output ('  APPLY FAILED ITS READ-BACK, file untouched: ' + $res.verifyFail); $code = 1 }
  elseif ($res.wrote) { Write-Output ('  APPLIED: stamped link_url on {0} row(s) of {1}, read back clean before the file was replaced' -f $res.stamped, $res.rows) }
  else { Write-Output '  APPLIED: nothing matched, nothing written' }
}
if ($code -eq 0 -and $res.window -gt 0 -and $res.resolved -eq 0) {
  Write-Output '  COULD NOT EVALUATE: window rows exist and not one of their captures could be read'
  $code = 3
}
Write-Output ('BACKFILL-ALDI-LINK-URLS-COMPLETE mode={0} matched={1} of {2} exit={3}' -f $(if ($doApply) { 'apply' } else { 'dry-run' }), $matchedN, $res.window, $code)
exit $code
