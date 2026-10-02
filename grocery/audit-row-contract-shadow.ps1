# audit-row-contract-shadow.ps1 - the capture row contract, run in SHADOW over every store's priced rows.
# ---------------------------------------------------------------------------------------------------
# Build step 8 (ruling 2), design/SPEC-capture-row-contract.md. Brad's D1 ruling, 2026-10-02: "write the contract
# and run it in SHADOW now, beside R18 and R11. Shadow refuses nothing and moves no price". So this script WRITES ONE
# GITIGNORED REPORT (out\row-contract-shadow-<date>.json) and nothing else: no board, no builder output, no cell, no
# alert. Enforcement, store by store after R18 / R11 and 7 shadow days, calls the same Get-TcRowContract inside
# each builder.
#
# WHAT IT READS.
#   * out\candidates-<date>.json, the engine's own join of EVERY captured row to its commodity (all seven builders'
#     regular / deals files, the two batch importers' rows inside them, and the weekly ads). The contract needs the
#     commodity's unit and declarations, and only this file carries the row-to-commodity join; reading it means no
#     builder and no matcher is re-run here.
#   * the newest output of each of the seven builders (out\regular\<store>-regular-*.json, out\sams\sams-deals-*.json),
#     to attribute each candidate row to the builder or importer (written_by) that wrote it, to carry each row's store
#     unit-price proof (qty_basis, sams_unit_price_proven, Baker's size_basis) into the contract, and to report any
#     builder whose rows lack a source text the contract reads (item, size, ad_price).
#   * grocery\commodities.json (unit, weight_is_one_unit, pack_is_package, pint_oz, kind_equivalent) and
#     grocery\basis-kind-allowlist.json (a reviewed size string is not a kind refusal).
# WHAT A CELL "THE CONTRACT WOULD EMPTY" MEANS: a commodity x store pair with at least one row the engine priced,
# where the contract refuses every one of those rows. A row the contract REPRICES (proves a different basis) does not
# empty a cell; it is counted separately.
#
# SCOPE OF A CLEAN REPORT: UNSOUND. A row the contract accepts can still be a wrong product or a wrong price; and a
# candidates file older than the board is reported by date, never silently. INCOMPLETE: a refusal is a basis the row
# cannot prove (gr-08), a candidate defect, not a proven one.
#
#   .\audit-row-contract-shadow.ps1                    newest candidates file under out\
#   .\audit-row-contract-shadow.ps1 -Store Aldi        ruling 6: one store (a new store, feed or batch) only
#   .\audit-row-contract-shadow.ps1 -SelfTest          hermetic cases for the cell and denominator arithmetic
# Exit 0 = ran (findings are the report, never a failure). Exit 3 = BLIND (no candidates or no catalog). Last line:
# ROW-CONTRACT-SHADOW-COMPLETE.
# gate-inputs: grocery\audit-row-contract-shadow.ps1, grocery\row-contract-lib.ps1, grocery\pricing-math-lib.ps1, grocery\pu-lib.ps1, grocery\ad-line-price-lib.ps1, lib\json-io.ps1, lib\atomic-write.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([string]$OutDir = '', [string]$CandidatesFile = '', [string]$CatalogFile = '', [string]$ReportDir = '',
      [string]$Store = '', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path (Split-Path $root -Parent) 'lib\json-io.ps1')
. (Join-Path (Split-Path $root -Parent) 'lib\atomic-write.ps1')
. (Join-Path $root 'row-contract-lib.ps1')

# Which builder writes which store's file. The store names are the candidates file's own; a store missing here is
# reported as 'no builder mapped', never dropped.
$script:RcBuilders = @(
  @{ store = 'Walmart';     builder = 'build-walmart-deals.ps1';     dir = 'regular'; prefix = 'walmart-regular' }
  @{ store = 'Aldi';        builder = 'build-aldi-regular.ps1';      dir = 'regular'; prefix = 'aldi-regular' }
  @{ store = 'Fareway';     builder = 'build-fareway-regular.ps1';   dir = 'regular'; prefix = 'fareway-regular' }
  @{ store = "Sam's Club";  builder = 'build-sams-deals.ps1';        dir = 'sams';    prefix = 'sams-deals' }
  @{ store = 'Hy-Vee';      builder = 'pull-regular-hyvee.ps1';      dir = 'regular'; prefix = 'hyvee-regular' }
  @{ store = 'Family Fare'; builder = 'pull-regular-familyfare.ps1'; dir = 'regular'; prefix = 'family-fare-regular' }
  @{ store = "Baker's";     builder = 'pull-regular-bakers-api.ps1'; dir = 'regular'; prefix = 'bakers-regular' }
)
function Get-RcNorm([string]$s) { return ((([string]$s) -replace '\s+', ' ').Trim().ToLower()) }

# THE TALLY, pure over (row results), so the self-test reaches it with no file. Each input: @{ id; store; producer;
# engine_priced; engine_basis; result }.
function Measure-RcShadow($Evals) {
  $stores = [ordered]@{}; $cells = @{}; $producers = [ordered]@{}
  foreach ($e in $Evals) {
    $st = [string]$e.store
    if (-not $stores.Contains($st)) { $stores[$st] = [ordered]@{ examined = 0; engine_priced = 0; refused_of_priced = 0; refused_of_unpriced = 0; repriced = 0; out_of_band = 0; out_of_band_with_basis_code = 0; by_code = [ordered]@{}; by_code_of_priced = [ordered]@{}; by_reprice = [ordered]@{} } }
    $s = $stores[$st]; $s.examined++
    $pr = [string]$e.producer; if (-not $producers.Contains($pr)) { $producers[$pr] = [ordered]@{ examined = 0; refused = 0 } }
    $producers[$pr].examined++
    $v = [string]$e.result.verdict
    if ($v -eq 'refuse') { $producers[$pr].refused++ }
    foreach ($rf in $e.result.refusals) { $c = [string]$rf.code; if (-not $s.by_code.Contains($c)) { $s.by_code[$c] = 0 }; $s.by_code[$c]++; if ($e.engine_priced) { if (-not $s.by_code_of_priced.Contains($c)) { $s.by_code_of_priced[$c] = 0 }; $s.by_code_of_priced[$c]++ } }
    foreach ($rp in $e.result.reprice) { $c = [string]$rp.code; if (-not $s.by_reprice.Contains($c)) { $s.by_reprice[$c] = 0 }; $s.by_reprice[$c]++ }
    if ($v -eq 'reprice') { $s.repriced++ }
    if ([string]$e.engine_basis -eq 'OUT-OF-BAND') { $s.out_of_band++; if ($v -eq 'refuse') { $s.out_of_band_with_basis_code++ } }
    if ($e.engine_priced) {
      $s.engine_priced++
      if ($v -eq 'refuse') { $s.refused_of_priced++ }
      $k = [string]$e.id + '|' + $st
      if (-not $cells.ContainsKey($k)) { $cells[$k] = @{ id = [string]$e.id; store = $st; priced = 0; surviving = 0; codes = @{}; rows = New-Object 'System.Collections.Generic.List[string]' } }
      $cl = $cells[$k]; $cl.priced++
      if ($v -ne 'refuse') { $cl.surviving++ } else {
        foreach ($rf in $e.result.refusals) { $cl.codes[[string]$rf.code] = $true }
        if ($cl.rows.Count -lt 3) { $cl.rows.Add([string]$e.name) }
      }
    } elseif ($v -eq 'refuse') { $s.refused_of_unpriced++ }
  }
  $empty = New-Object 'System.Collections.Generic.List[object]'
  foreach ($k in ($cells.Keys | Sort-Object)) {
    $cl = $cells[$k]
    if ($cl.priced -gt 0 -and $cl.surviving -eq 0) { $empty.Add([ordered]@{ id = $cl.id; store = $cl.store; priced_rows = $cl.priced; codes = @($cl.codes.Keys | Sort-Object); rows = @($cl.rows.ToArray()) }) }
  }
  foreach ($st in @($stores.Keys)) {
    $stores[$st]['priced_cells'] = @($cells.Values | Where-Object { $_.store -eq $st }).Count
    $stores[$st]['cells_would_empty'] = @($empty | Where-Object { $_.store -eq $st }).Count
  }
  return [ordered]@{ stores = $stores; producers = $producers; cells_would_empty = $empty.ToArray(); priced_cells = $cells.Count }
}

if ($SelfTest) {
  $f = 0; $n = 0
  function _RcCase([string]$name, [bool]$ok, [string]$got) { $script:n++; if ($ok) { Write-Output "  ok    $name" } else { $script:f++; Write-Output "  FAIL  $name  (got: $got)" } }
  $script:n = 0; $script:f = 0
  try {
    $acc = @{ verdict = 'accept'; refusals = @(); reprice = @() }
    $ref = @{ verdict = 'refuse'; refusals = @(@{ code = 'KIND-VOLUME-ON-WEIGHT' }); reprice = @() }
    $rep = @{ verdict = 'reprice'; refusals = @(); reprice = @(@{ code = 'PACK-COUNT-IGNORED' }) }
    $ev = @(
      @{ id = 'condensed-milk'; store = 'Aldi'; producer = 'build-aldi-regular.ps1'; name = 'a'; engine_priced = $true; engine_basis = 'size 14 oz'; result = $ref }
      @{ id = 'condensed-milk'; store = 'Walmart'; producer = 'build-walmart-deals.ps1'; name = 'b'; engine_priced = $true; engine_basis = 'size 14 oz'; result = $ref }
      @{ id = 'condensed-milk'; store = 'Walmart'; producer = 'build-walmart-deals.ps1'; name = 'c'; engine_priced = $true; engine_basis = 'size 14 oz'; result = $acc }
      @{ id = 'soda'; store = 'Aldi'; producer = 'build-aldi-regular.ps1'; name = 'd'; engine_priced = $true; engine_basis = 'size 16.9 floz'; result = $rep }
      @{ id = 'soda'; store = 'Aldi'; producer = 'ad or other feed'; name = 'e'; engine_priced = $false; engine_basis = 'OUT-OF-BAND'; result = $ref }
    )
    $m = Measure-RcShadow $ev
    $empty = @($m.cells_would_empty)
    _RcCase 'MUST FIRE  a cell whose only priced row is refused is named as would-empty (condensed-milk|Aldi)' (($empty.Count -eq 1) -and $empty[0].id -eq 'condensed-milk' -and $empty[0].store -eq 'Aldi') (($empty | ForEach-Object { $_.id + '|' + $_.store }) -join ',')
    _RcCase 'MUST NOT FIRE  a cell with one refused and one accepted priced row is not emptied (condensed-milk|Walmart)' (@($empty | Where-Object { $_.store -eq 'Walmart' }).Count -eq 0) ''
    _RcCase 'MUST NOT FIRE  a repriced row keeps its cell (soda|Aldi is not emptied)' (@($empty | Where-Object { $_.id -eq 'soda' }).Count -eq 0) ''
    $a = $m.stores['Aldi']
    _RcCase 'CLEAN TWIN  denominators: Aldi examined 3, engine priced 2, refused 1 of priced, 1 of unpriced, 1 out-of-band with a basis code, 2 priced cells' (($a.examined -eq 3) -and ($a.engine_priced -eq 2) -and ($a.refused_of_priced -eq 1) -and ($a.refused_of_unpriced -eq 1) -and ($a.out_of_band_with_basis_code -eq 1) -and ($a.priced_cells -eq 2) -and ($a.cells_would_empty -eq 1)) ($a | ConvertTo-Json -Compress -Depth 4)
  } catch { $script:f++; Write-Output ('  FAIL  threw: ' + $_.Exception.Message) }
  if ($script:n -ne 4) { $script:f++; Write-Output ("  FAIL  ran {0} of 4 cases" -f $script:n) }
  if ($script:f) { Write-Output ('audit-row-contract-shadow self-test FAIL: ' + $script:f + ' check(s)'); exit 1 }
  Write-Output ('audit-row-contract-shadow self-test pass: ' + $script:n + ' cases')
  exit 0
}

# ---------------------------------------------------------------- LIVE
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $CatalogFile) { $CatalogFile = Join-Path $root 'commodities.json' }
if (-not $ReportDir) { $ReportDir = $OutDir }
if (-not $CandidatesFile) {
  $cf = @(Get-ChildItem (Join-Path $OutDir 'candidates-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^candidates-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending)
  if ($cf.Count) { $CandidatesFile = $cf[0].FullName }
}
if (-not $CandidatesFile -or -not (Test-Path -LiteralPath $CandidatesFile)) {
  Write-Output ('ROW-CONTRACT-SHADOW BLIND: no candidates-<date>.json under ' + $OutDir + ' - the engine has not written its row-to-commodity join here, so nothing was examined')
  Write-Output 'ROW-CONTRACT-SHADOW-COMPLETE blind=no-candidates examined=0'
  exit 3
}
if (-not (Test-Path -LiteralPath $CatalogFile)) {
  Write-Output ('ROW-CONTRACT-SHADOW BLIND: no catalog at ' + $CatalogFile)
  Write-Output 'ROW-CONTRACT-SHADOW-COMPLETE blind=no-catalog examined=0'
  exit 3
}
$catDoc = Read-JsonFile $CatalogFile
$catList = @(if ($catDoc -is [array]) { $catDoc } elseif ($catDoc.PSObject.Properties['commodities']) { $catDoc.commodities } else { @() })
$cat = @{}; foreach ($c in $catList) { if ($c.id) { $cat[[string]$c.id] = $c } }
$reviewed = @{}
$alw = Join-Path $root 'basis-kind-allowlist.json'
if (Test-Path -LiteralPath $alw) { foreach ($a in @((Read-JsonFile $alw).allow)) { $reviewed[([string]$a.id + '|' + [string]$a.store + '|' + (Get-RcNorm $a.size))] = $true } }

# ---- the builders' own outputs: attribution, unit-price proof, source-field check
$builderReport = New-Object 'System.Collections.Generic.List[object]'
$index = @{}
foreach ($b in $script:RcBuilders) {
  if ($Store -and $b.store -ne $Store) { continue }
  $files = @(Get-ChildItem (Join-Path (Join-Path $OutDir $b.dir) ($b.prefix + '-*.json')) -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match ('^' + [regex]::Escape($b.prefix) + '-\d{4}-\d{2}-\d{2}$') } | Sort-Object Name -Descending)
  if ($files.Count -eq 0) { $builderReport.Add([ordered]@{ store = $b.store; builder = $b.builder; file = $null; rows = 0; note = 'no output file found' }); continue }
  $doc = Read-JsonFile $files[0].FullName
  $rows = @(if ($doc.PSObject.Properties['deals']) { $doc.deals } else { @() })
  $missing = [ordered]@{ item = 0; size = 0; ad_price = 0 }
  $byProducer = [ordered]@{}
  foreach ($row in $rows) {
    foreach ($fld in @('item', 'size', 'ad_price')) { if (-not $row.PSObject.Properties[$fld] -or -not ([string]$row.$fld).Trim()) { $missing[$fld]++ } }
    $prod = if ($row.PSObject.Properties['written_by'] -and $row.written_by) { [string]$row.written_by } else { $b.builder }
    if (-not $byProducer.Contains($prod)) { $byProducer[$prod] = 0 }; $byProducer[$prod]++
    $k = $b.store + '|' + (Get-RcNorm $row.item)
    if (-not $index.ContainsKey($k)) {
      $proof = ''
      if ($row.PSObject.Properties['qty_basis'] -and ([string]$row.qty_basis) -match '(?i)reproduces') { $proof = [string]$row.qty_basis }
      elseif ($row.PSObject.Properties['sams_unit_price_proven'] -and $row.sams_unit_price_proven) { $proof = 'sams_unit_price_proven' }
      elseif ($row.PSObject.Properties['size_basis'] -and ([string]$row.size_basis) -match '(?i)net') { $proof = 'size_basis ' + [string]$row.size_basis }
      $index[$k] = @{ producer = $prod; proof = $proof }
    }
  }
  $builderReport.Add([ordered]@{ store = $b.store; builder = $b.builder; file = $files[0].Name; rows = $rows.Count; rows_by_producer = $byProducer; rows_missing_source_field = $missing })
  # A candidate row can come from an older capture (src_date), and Walmart's and Sam's rows carry the store's own unit price, so their
  # proof is read from the newest 14 files as well. First hit wins; attribution stays with the newest file's producer when it has the row.
  if ($b.store -eq 'Walmart' -or $b.store -eq "Sam's Club") {
    foreach ($of in @($files | Select-Object -Skip 1 -First 13)) {
      $od = Read-JsonFile $of.FullName
      foreach ($row in @(if ($od.PSObject.Properties['deals']) { $od.deals } else { @() })) {
        $k = $b.store + '|' + (Get-RcNorm $row.item)
        $pf = ''
        if ($row.PSObject.Properties['qty_basis'] -and ([string]$row.qty_basis) -match '(?i)reproduces') { $pf = [string]$row.qty_basis }
        elseif ($row.PSObject.Properties['sams_unit_price_proven'] -and $row.sams_unit_price_proven) { $pf = 'sams_unit_price_proven' }
        if (-not $index.ContainsKey($k)) { $index[$k] = @{ producer = $(if ($row.PSObject.Properties['written_by'] -and $row.written_by) { [string]$row.written_by } else { $b.builder }); proof = $pf } }
        elseif ($pf -and -not $index[$k].proof) { $index[$k].proof = $pf }
      }
    }
  }
}

# ---- the contract over every candidate row
$cand = Read-JsonFile $CandidatesFile
$evals = New-Object 'System.Collections.Generic.List[object]'
$sw = [Diagnostics.Stopwatch]::StartNew()
$noCommodity = 0
foreach ($c in @($cand.commodities)) {
  $decl = if ($cat.ContainsKey([string]$c.id)) { $cat[[string]$c.id] } else { $noCommodity++; [pscustomobject]@{ id = $c.id; unit = $c.unit } }
  # the candidates file's unit is the one the engine divided by; the catalog's declarations ride with it
  $com = @{ id = [string]$c.id; unit = [string]$c.unit }
  foreach ($p in @('weight_is_one_unit', 'pack_is_package', 'pint_oz', 'kind_equivalent', 'density_g_ml')) { if ($decl.PSObject.Properties[$p]) { $com[$p] = $decl.$p } }
  foreach ($r in @($c.candidates)) {
    if ($Store -and [string]$r.store -ne $Store) { continue }
    $hit = $index[[string]$r.store + '|' + (Get-RcNorm $r.name)]
    $row = [pscustomobject]@{ store = $r.store; name = $r.name; price_text = $r.price_text; size_text = $r.size_text; regular = $r.regular; price_type = $r.price_type; qty_basis = $(if ($hit -and $hit.proof) { $hit.proof } else { '' }) }
    $kr = $reviewed.ContainsKey([string]$c.id + '|' + [string]$r.store + '|' + (Get-RcNorm $r.size_text))
    $res = Get-TcRowContract $row $com -KindReviewed:$kr
    $up = $r.unit_price
    $evals.Add(@{ id = [string]$c.id; store = [string]$r.store; name = [string]$r.name; producer = $(if ($hit) { $hit.producer } else { 'ad or other feed' }); engine_priced = ($null -ne $up -and [string]$up -ne ''); engine_basis = [string]$r.basis; result = $res })
  }
}
$sw.Stop()
$m = Measure-RcShadow $evals
$candName = Split-Path $CandidatesFile -Leaf
$date = ([regex]::Match($candName, '\d{4}-\d{2}-\d{2}')).Value
$libHash = (Get-FileHash -LiteralPath (Join-Path $root 'row-contract-lib.ps1') -Algorithm SHA1).Hash.ToLower()
$report = [ordered]@{
  generated = (Get-Date).ToString('s'); candidates_file = $candName; board_date = $date; store_filter = $Store
  mode = 'SHADOW: refuses nothing, changes no price, board or builder output'
  lib_sha1 = $libHash; elapsed_s = [int]$sw.Elapsed.TotalSeconds; commodities_not_in_catalog = $noCommodity
  total = [ordered]@{ examined = $evals.Count; priced_cells = $m.priced_cells; cells_would_empty = @($m.cells_would_empty).Count }
  stores = $m.stores; producers = $m.producers; builders = @($builderReport.ToArray()); cells_would_empty = @($m.cells_would_empty)
}
$suffix = if ($Store) { '-' + (($Store.ToLower()) -replace '[^a-z0-9]+', '-').Trim('-') } else { '' }
$repPath = Join-Path $ReportDir ('row-contract-shadow-' + $date + $suffix + '.json')
[void](Write-TcAtomicFile -Path $repPath -Text ($report | ConvertTo-Json -Depth 8) -NoBom)

foreach ($st in @($m.stores.Keys)) {
  $s = $m.stores[$st]
  $pct = if ($s.engine_priced) { [math]::Round(100.0 * $s.refused_of_priced / $s.engine_priced, 1) } else { 0 }
  $codes = (@($s.by_code_of_priced.Keys | ForEach-Object { $_ + '=' + $s.by_code_of_priced[$_] }) -join ' ')
  Write-Output ('ROW-CONTRACT-SHADOW ' + $st + ': examined ' + $s.examined + ' row(s); the contract would refuse ' + $s.refused_of_priced + ' of ' + $s.engine_priced + ' engine-priced (' + $pct + '%) and agrees on ' + $s.refused_of_unpriced + ' the engine already left unpriced; reprices ' + $s.repriced + '; would empty ' + $s.cells_would_empty + ' of ' + $s.priced_cells + ' priced cell(s); out-of-band rows with a basis code ' + $s.out_of_band_with_basis_code + ' of ' + $s.out_of_band + '; refusals of engine-priced rows by code [' + $codes + ']')
}
foreach ($b in $builderReport) {
  $miss = if ($b.rows_missing_source_field) { (@($b.rows_missing_source_field.Keys | Where-Object { $b.rows_missing_source_field[$_] -gt 0 } | ForEach-Object { $_ + '=' + $b.rows_missing_source_field[$_] }) -join ' ') } else { '' }
  Write-Output ('  builder ' + $b.builder + ': ' + $(if ($b.file) { $b.file + ', ' + $b.rows + ' row(s)' } else { $b.note }) + $(if ($miss) { '; rows missing a source field: ' + $miss } else { '' }))
}
Write-Output ('ROW-CONTRACT-SHADOW-COMPLETE examined=' + $evals.Count + ' cells_would_empty=' + @($m.cells_would_empty).Count + ' of ' + $m.priced_cells + ' report=' + (Split-Path $repPath -Leaf) + ' elapsed_s=' + [int]$sw.Elapsed.TotalSeconds)
exit 0
