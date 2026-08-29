<#
  add-recipe-board-rows.ps1 - append NEW commodity rows to out\recipe-board-everyday.json from adjudicated
  per-store capture evidence.

  WHY THIS EXISTS. recipe-board-everyday.json is the everyday floor baseline for recipe-only commodities -
  the ids that deliberately do NOT live on the weekly staples board because a broader staples row would
  steal their cells under first-match-wins (yellow-bell-pepper vs bell-peppers, the jack cheeses vs
  shredded-cheese, shaved-beef-steak vs sirloin-steak/ribeye-steak, beef-base vs bouillon). Every one of the
  156 rows already in that file arrived by hand. derive-recipe-floors.ps1 -Apply REFRESHES existing rows
  from the weekly candidates; it has never been able to ADD one, so the one operation the file needs most
  was the one with no gated path and no proof contract. This is that path.

  SAME SAFETY CONTRACT AS new-commodity.ps1: text-level append, never a whole-file reserialize (the file
  carries \uXXXX-escaped store names - Sam's Club, Baker's - that a ConvertTo-Json round trip rewrites), and
  after writing it re-parses and proves every PRE-EXISTING row is byte-identical. Row count must go up by
  exactly the number of rows offered. Anything else is a hard failure and nothing is written.

  IT REFUSES TO INVENT A PRICE. Each store cell must carry item, size and a price; per_unit is computed here
  from price and size so the arithmetic is visible and reproducible rather than pre-chewed by the caller.
  A cell whose size does not resolve in the row's unit is REFUSED, not guessed - a per_unit on a false basis
  is the brown-sugar 16x class, and it publishes as a real number.

  -REPLACE: THE ROW EXISTS AND IS WRONG (2026-08-28). Appending was the only operation until today,
  and it could not fix the defect that made this necessary: `cheddar-cheese`, `cheddar-cheese-shredded`
  and `mozzarella-cheese` all carried BYTE-IDENTICAL rows - Sam's part-skim mozzarella, Aldi
  mozzarella, a Walmart Fiesta blend - because derive-recipe-floors refreshes a recipe row from the
  weekly candidates its floor-map entry points at, and all three point at the generic basket. Three
  different cheeses, one set of cells, and 85 live recipes priced by whichever cheese was cheapest.
  Nothing in the estate could rewrite those cells.

  IT IS THE SAME EDIT, NOT A LOOSER ONE. -Replace still demands item, size and price on every cell,
  still computes per_unit here, still refuses a size it cannot resolve in the row's unit, and still
  proves that every OTHER row is byte-identical afterwards. What changes is only WHICH row may be
  written: with -Replace the id must ALREADY exist (and without it, must not). The row count must come
  back unchanged, which is the replace-shaped version of "up by exactly the rows offered".

  AND THE FLOOR MAP HAS TO GO FIRST, or the next derive-recipe-floors run stamps the generic cells
  straight back over the new ones. That is a separate edit to recipe-floor-id-map.json and this script
  does not make it; it prints the reminder.

  A row whose id is already on the PRICED weekly board is refused: recipe-overlay.ps1 would drop it on the
  next run anyway, and a row that exists only to be dropped is a second price for one commodity.

  Usage:
    .\add-recipe-board-rows.ps1 -RowsFile rows.json            # dry run, prints the computed board
    .\add-recipe-board-rows.ps1 -RowsFile rows.json -Apply
    .\add-recipe-board-rows.ps1 -RowsFile rows.json -Replace -Apply   # rewrite rows that exist
    .\add-recipe-board-rows.ps1 -SelfTest

  RowsFile shape:
    [ { "id":"beef-base", "commodity":"Beef Base", "category":"Canned & Soup", "unit":"oz",
        "stores":[ {"store":"Walmart","price":2.77,"size":"7.9 oz","item":"Knorr ... Beef Bouillon"} ] } ]

  Exit 0 = written (or dry run clean). Exit 1 = refused, nothing written.
#>
param(
  [string]$RowsFile = '',
  [string]$BoardFile = '',
  [string]$OutDir = '',
  [switch]$Apply,
  [switch]$Replace,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir)    { $OutDir    = Join-Path $root 'out' }
if (-not $BoardFile) { $BoardFile = Join-Path $OutDir 'recipe-board-everyday.json' }
function Say([string]$s) { Write-Output $s }
function Die([string]$s) { Write-Output ('add-recipe-board-rows: ' + $s); exit 1 }

# The seven Omaha stores, spelled exactly as every board row and capture spells them. A row recording
# 'Bakers' or 'Sams Club' creates a silent eighth store that nothing downstream can join on.
$STORES = @("Baker's", 'Family Fare', 'Hy-Vee', 'Aldi', 'Fareway', "Sam's Club", 'Walmart')
$UNITS  = @('lb', 'oz', 'floz', 'each', 'dozen', 'gallon')

# Size -> magnitude in the ROW'S unit. Only the shapes the captures actually emit; an unrecognised token is
# refused rather than guessed. Mirrors export-feed.ps1's UNIT_ALIAS/ConvertTo-RowUnit deliberately - the two
# must agree or the feed will re-derive a different package basis from the same string.
$ALIAS = @{
  'oz'='oz'; 'ounce'='oz'; 'ounces'='oz'
  'lb'='lb'; 'lbs'='lb'; 'pound'='lb'; 'pounds'='lb'
  'floz'='floz'; 'fl oz'='floz'; 'fluid ounce'='floz'; 'fluid ounces'='floz'
  'ct'='each'; 'count'='each'; 'ea'='each'; 'each'='each'; 'pk'='each'; 'pack'='each'
  'g'='g'; 'gram'='g'; 'grams'='g'; 'kg'='kg'
  'ml'='ml'; 'l'='l'; 'liter'='l'; 'litre'='l'
  'gal'='gal'; 'gallon'='gal'; 'qt'='qt'; 'quart'='qt'; 'pt'='pt'; 'pint'='pt'
  'dozen'='dozen'; 'dz'='dozen'
}
function ConvertTo-RowUnit([double]$mag, [string]$from, [string]$to) {
  if ($from -eq $to) { return $mag }
  switch ("$from>$to") {
    'oz>lb'    { return $mag / 16 }
    'lb>oz'    { return $mag * 16 }
    'g>lb'     { return $mag / 453.59237 }
    'g>oz'     { return $mag / 28.349523 }
    'kg>lb'    { return $mag * 2.2046226 }
    'kg>oz'    { return $mag * 35.273962 }
    'gal>floz' { return $mag * 128 }
    'qt>floz'  { return $mag * 32 }
    'pt>floz'  { return $mag * 16 }
    'l>floz'   { return $mag * 33.814023 }
    'ml>floz'  { return $mag / 29.573530 }
    'each>dozen' { return $mag / 12 }
    # The board's own convention, mirrored from export-feed.ps1: on a row already established as a liquid,
    # a package labelled "32 oz" is 32 FLUID ounces. Allowed in this one direction only; every other
    # weight/volume crossing is refused below, because guessing one is a wrong price.
    'oz>floz'  { return $mag }
    default    { return 0 }
  }
}
function Resolve-Size([string]$size, [string]$rowUnit) {
  # Returns magnitude in $rowUnit, or 0 when it cannot be proven.
  $s = ([string]$size).Trim()
  if (-not $s) { return 0 }
  # multipack "16 oz x 2 pk (32 oz)" / "2.5 lbs" / "12 ct (dozen)" - take a trailing parenthesised total first
  if ($s -match '\(\s*([\d.]+)\s*([a-zA-Z][a-zA-Z.\s]*?)\s*\)\s*$') {
    $m = [double]$Matches[1]; $u = ($Matches[2] -replace '\.','' -replace '\s+',' ').Trim().ToLower()
    if ($ALIAS.ContainsKey($u)) { $v = ConvertTo-RowUnit $m $ALIAS[$u] $rowUnit; if ($v -gt 0) { return $v } }
  }
  if ($s -match '^\s*([\d.]+)\s*([a-zA-Z][a-zA-Z.\s]*?)\s*$') {
    $m = [double]$Matches[1]; $u = ($Matches[2] -replace '\.','' -replace '\s+',' ').Trim().ToLower()
    if ($ALIAS.ContainsKey($u)) { $v = ConvertTo-RowUnit $m $ALIAS[$u] $rowUnit; if ($v -gt 0) { return $v } }
  }
  # bare "each" / "lb" with no magnitude means one unit of the row's own basis
  $bare = ($s -replace '[^a-zA-Z]',' ' -replace '\s+',' ').Trim().ToLower()
  if ($ALIAS.ContainsKey($bare) -and $ALIAS[$bare] -eq $rowUnit) { return 1 }
  return 0
}

if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) { if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ } }
  T 'plain oz size resolves on an oz row'        ([math]::Abs((Resolve-Size '7.9 oz' 'oz') - 7.9) -lt 1e-9) ([string](Resolve-Size '7.9 oz' 'oz'))
  T 'lb size converts onto an oz row'            ([math]::Abs((Resolve-Size '2.5 lbs' 'oz') - 40) -lt 1e-6) ([string](Resolve-Size '2.5 lbs' 'oz'))
  T 'ml converts onto a floz row'                ([math]::Abs((Resolve-Size '750 ml' 'floz') - 25.360517) -lt 1e-4) ([string](Resolve-Size '750 ml' 'floz'))
  T 'parenthesised multipack total wins'         ([math]::Abs((Resolve-Size '16 oz x 2 pk (32 oz)' 'oz') - 32) -lt 1e-9) ([string](Resolve-Size '16 oz x 2 pk (32 oz)' 'oz'))
  T 'a bare each on an each row is one unit'     ([math]::Abs((Resolve-Size '1 each' 'each') - 1) -lt 1e-9) ([string](Resolve-Size '1 each' 'each'))
  # MUST FIRE: a weight size on a volume row is not convertible and must never be guessed at.
  T 'MUST FIRE  grams on an each row is refused' ((Resolve-Size '588 g' 'each') -eq 0) ([string](Resolve-Size '588 g' 'each'))
  T 'MUST FIRE  an unparseable size is refused'  ((Resolve-Size 'per lb marker' 'oz') -eq 0) ([string](Resolve-Size 'per lb marker' 'oz'))
  T 'MUST FIRE  an empty size is refused'        ((Resolve-Size '' 'oz') -eq 0) '0'
  # ---- -Replace, end to end against a scratch board -----------------------------------------------
  # The pure Resolve-Size cases above cannot see the write road at all, and -Replace is a WRITE. What
  # it must guarantee is narrow and testable: the named row changes, no other row moves, the count
  # stays put, and a rewrite that changed nothing is refused rather than reported as success.
  $rt = Join-Path ([IO.Path]::GetTempPath()) ('arbr-replace-' + [guid]::NewGuid().ToString('N'))
  [void](New-Item -ItemType Directory -Path $rt)
  try {
    # the guard demands 100+ existing rows before it will believe the file parsed, so the scratch
    # board carries filler; two of the rows are the ones the cases actually touch.
    $fill = @()
    for ($i = 1; $i -le 120; $i++) {
      $fill += [ordered]@{ id = ('filler-' + $i); commodity = ('Filler ' + $i); category = 'Dairy & Eggs'
                           unit = 'oz'; cheapest_store = 'Aldi'
                           stores = @([ordered]@{ store = 'Aldi'; per_unit = 1.0; type = 'everyday'
                                                  bulk = $false; item = ('Thing ' + $i); size = '8 oz' }) }
    }
    $fill += [ordered]@{ id = 'target-cheese'; commodity = 'Target Cheese'; category = 'Dairy & Eggs'
                         unit = 'oz'; cheapest_store = 'Aldi'
                         stores = @([ordered]@{ store = 'Aldi'; per_unit = 9.99; type = 'everyday'
                                                bulk = $false; item = 'WRONG PRODUCT'; size = '8 oz' }) }
    $bf = Join-Path $rt 'board.json'
    [IO.File]::WriteAllText($bf, (ConvertTo-Json @{ comparison = $fill } -Depth 9), (New-Object System.Text.UTF8Encoding($false)))
    $od = Join-Path $rt 'out'; [void](New-Item -ItemType Directory -Path $od)

    function RowsFile([string]$id, [string]$item, [double]$price) {
      $f = Join-Path $rt ('rows-' + [guid]::NewGuid().ToString('N') + '.json')
      $o = @(@{ id = $id; commodity = 'Target Cheese'; category = 'Dairy & Eggs'; unit = 'oz'
                stores = @(@{ store = 'Aldi'; price = $price; size = '8 oz'; item = $item }) })
      [IO.File]::WriteAllText($f, (ConvertTo-Json $o -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
      return $f
    }
    function Board { (Get-Content $bf -Raw | ConvertFrom-Json).comparison }
    function Row([string]$id) { @(Board) | Where-Object { $_.id -eq $id } }
    # HASHTABLE SPLAT, NOT AN ARRAY ONE. `& $script @array` binds the elements POSITIONALLY, so
    # '-RowsFile' arrives as the VALUE of $RowsFile and every case dies on "rows file not found:
    # -RowsFile" - including two that were asserting a refusal and so went green on the wrong error.
    # A hashtable splat is the only form that passes named parameters.
    function Run([hashtable]$p) { $o = & $PSCommandPath @p; return @{ rc = $LASTEXITCODE; out = ($o -join ' | ') } }

    $r = Run @{ RowsFile = (RowsFile 'target-cheese' 'RIGHT PRODUCT' 2.0); BoardFile = $bf; OutDir = $od; Replace = $true; Apply = $true }
    $row = Row 'target-cheese'
    T '-Replace rewrites the named row in place'  ($r.rc -eq 0 -and [string]$row.stores[0].item -eq 'RIGHT PRODUCT' -and [double]$row.stores[0].per_unit -eq 0.25) ($r.out)
    T '  ...and the row COUNT does not move'      (@(Board).Count -eq 121) (@(Board).Count.ToString())
    T '  ...and no other row changed'             ([string](Row 'filler-7').stores[0].item -eq 'Thing 7' -and [string](Row 'filler-120').stores[0].item -eq 'Thing 120') 'a filler row moved'

    # MUST FIRE: -Replace on an id that is not there is a typo, not an add.
    $r = Run @{ RowsFile = (RowsFile 'no-such-id' 'X' 2.0); BoardFile = $bf; OutDir = $od; Replace = $true; Apply = $true }
    T 'MUST FIRE  -Replace on an id with no row is refused' ($r.rc -ne 0 -and @(Board).Count -eq 121) $r.out

    # MUST FIRE: appending over an existing id still refuses, and now says how to rewrite it.
    $r = Run @{ RowsFile = (RowsFile 'target-cheese' 'Y' 2.0); BoardFile = $bf; OutDir = $od; Apply = $true }
    T 'MUST FIRE  an APPEND over an existing id is still refused' ($r.rc -ne 0 -and $r.out -match 'Replace') $r.out

    # MUST FIRE: a rewrite that changes nothing must not report success - that is how a wrong price
    # survives a run that claimed to correct it.
    $r = Run @{ RowsFile = (RowsFile 'target-cheese' 'RIGHT PRODUCT' 2.0); BoardFile = $bf; OutDir = $od; Replace = $true; Apply = $true }
    T 'MUST FIRE  a -Replace that changes NOTHING is refused' ($r.rc -ne 0 -and $r.out -match 'changed NOTHING') $r.out

    # MUST FIRE: the size gate is not relaxed by -Replace.
    $f = Join-Path $rt 'bad.json'
    [IO.File]::WriteAllText($f, (ConvertTo-Json @(@{ id = 'target-cheese'; commodity = 'Target Cheese'; category = 'Dairy & Eggs'; unit = 'oz'; stores = @(@{ store = 'Aldi'; price = 2.0; size = 'per lb marker'; item = 'Z' }) }) -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    $r = Run @{ RowsFile = $f; BoardFile = $bf; OutDir = $od; Replace = $true; Apply = $true }
    T 'MUST FIRE  -Replace still refuses a size it cannot resolve' ($r.rc -ne 0 -and [string](Row 'target-cheese').stores[0].item -eq 'RIGHT PRODUCT') $r.out

    # CLEAN TWIN: a dry run writes nothing on the replace road either.
    $b4 = Get-Content $bf -Raw
    $r = Run @{ RowsFile = (RowsFile 'target-cheese' 'DRYRUN ONLY' 3.0); BoardFile = $bf; OutDir = $od; Replace = $true }
    T 'CLEAN TWIN -Replace without -Apply writes nothing' ($r.rc -eq 0 -and (Get-Content $bf -Raw) -eq $b4) $r.out
  } finally { Remove-Item -Recurse -Force $rt -ErrorAction SilentlyContinue }

  if ($bad) { Write-Output ("add-recipe-board-rows SELF-TEST FAIL ({0})" -f $bad); exit 1 }
  Write-Output 'add-recipe-board-rows SELF-TEST PASS'; exit 0
}

if (-not $RowsFile) { Die 'pass -RowsFile <path> (or -SelfTest). An empty run would prove nothing.' }
if (-not (Test-Path $RowsFile))  { Die ('rows file not found: ' + $RowsFile) }
if (-not (Test-Path $BoardFile)) { Die ('board file not found: ' + $BoardFile) }

# ASSIGN THEN WRAP. `@(Get-Content -Raw | ConvertFrom-Json)` collapses a JSON array to ONE element in PS 5.1 -
# the marshalling trap that corrupted db\ingredients.json on 2026-08-16 and convinced an earlier session the
# estate owned 8 ingredients. Every array read in this file goes through this shape.
$parsedRows = Get-Content $RowsFile -Raw -Encoding utf8 | ConvertFrom-Json
$wanted = @($parsedRows)
if (@($wanted).Count -lt 1) { Die 'the rows file parsed to zero rows' }

$raw    = [IO.File]::ReadAllText($BoardFile, [Text.Encoding]::UTF8) -replace '^\xEF\xBB\xBF', ''
$before = $raw | ConvertFrom-Json
$bList  = New-Object System.Collections.ArrayList
foreach ($r in @($before.comparison)) { [void]$bList.Add($r) }
if ($bList.Count -lt 100) { Die ('parsed only ' + $bList.Count + ' existing board rows - implausible for this file; parse error, not data. Nothing written.') }
$haveIds = @{}; foreach ($r in $bList) { $haveIds[[string]$r.id] = $true }

# A row already on the PRICED weekly board would be dropped by recipe-overlay on its next run.
$stapleIds = @{}
$cmp = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^comparison-\d{4}-\d{2}-\d{2}\.json$' } | Sort-Object Name -Descending | Select-Object -First 1
if ($cmp) { foreach ($sr in @((Get-Content $cmp.FullName -Raw | ConvertFrom-Json).comparison)) { $stapleIds[[string]$sr.id] = $true } }

$catLabels = @{}
$catFile = Join-Path $root 'categories.json'
if (Test-Path $catFile) { foreach ($c in (Get-Content $catFile -Raw | ConvertFrom-Json).categories) { $catLabels[[string]$c.label] = $true } }

# ---- validate + compute every row BEFORE touching the file. Partial-but-safe beats all-or-nothing only when
# the parts are independent; here one bad row means the caller's evidence is wrong, so the batch is refused.
$built = New-Object System.Collections.ArrayList
$seen  = @{}
foreach ($w in $wanted) {
  $id = ([string]$w.id).Trim()
  if (-not $id -or ($id -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$')) { Die ("bad id '" + $id + "' - must be a kebab slug") }
  if ($seen.ContainsKey($id))    { Die ('dupe id within the batch: ' + $id) }
  if ($Replace) {
    if (-not $haveIds.ContainsKey($id)) { Die ("-Replace names id '" + $id + "' but there is no such row in " + (Split-Path -Leaf $BoardFile) + ". Replace rewrites a row that exists; drop -Replace to add one.") }
  }
  elseif ($haveIds.ContainsKey($id)) { Die ("id '" + $id + "' is already a row in " + (Split-Path -Leaf $BoardFile) + ". Pass -Replace to rewrite it.") }
  if ($stapleIds.ContainsKey($id)) { Die ("id '" + $id + "' is already PRICED on the weekly staples board - recipe-overlay would drop this row on its next run. Price it there instead.") }
  $seen[$id] = $true
  $unit = [string]$w.unit
  if ($UNITS -notcontains $unit) { Die ("bad unit '" + $unit + "' on " + $id) }
  $label = [string]$w.commodity
  if (-not $label) { Die ('blank commodity label on ' + $id) }
  $cat = [string]$w.category
  if ($catLabels.Count -gt 0 -and -not $catLabels.ContainsKey($cat)) { Die ("category '" + $cat + "' on " + $id + " is not a label in categories.json - build-deals-page cannot place it") }

  $cells = New-Object System.Collections.ArrayList
  foreach ($s in @($w.stores)) {
    $store = [string]$s.store
    if ($STORES -notcontains $store) { Die ("unknown store '" + $store + "' on " + $id + " - must be spelled exactly as the boards spell it") }
    $item = [string]$s.item
    if (-not $item) { Die ('a cell on ' + $id + ' (' + $store + ') carries no item name - identity travels with the price or not at all') }
    $price = [double]$s.price
    if ($price -le 0) { Die ('a cell on ' + $id + ' (' + $store + ') carries no price') }
    $mag = Resolve-Size ([string]$s.size) $unit
    if ($mag -le 0) { Die ("cannot resolve size '" + [string]$s.size + "' into " + $unit + " on " + $id + ' (' + $store + ") - refusing rather than guessing a basis") }
    $pu = $price / $mag
    [void]$cells.Add([pscustomobject]@{ store = $store; per_unit = [math]::Round($pu, 4); type = 'everyday'; bulk = [bool]$s.bulk; item = $item; size = [string]$s.size })
  }
  if ($cells.Count -lt 1) { Die ('row ' + $id + ' has no store cells') }
  $ranked = @($cells.ToArray() | Sort-Object per_unit)
  [void]$built.Add([pscustomobject]@{
    id = $id; commodity = $label; category = $cat; unit = $unit
    cheapest_store = [string]$ranked[0].store; stores = $ranked
  })
}

Say ('add-recipe-board-rows: ' + @($built).Count + ' row(s) computed from evidence, against ' + $bList.Count + ' existing rows')
foreach ($b in $built.ToArray()) {
  Say ('  {0,-30} {1,-34} [{2}] {3} cell(s), cheapest {4} @ {5}' -f $b.id, $b.commodity, $b.unit, @($b.stores).Count, $b.stores[0].per_unit, $b.cheapest_store)
  foreach ($c in $b.stores) { Say ('        {0,-13} {1,9}  {2,-22} {3}' -f $c.store, $c.per_unit, $c.size, $c.item) }
}

# ---- REPLACE: rewrite each named row's own text block, in place ---------------------------------------
# Text surgery for the same reason the append road uses it: this file carries \uXXXX-escaped store
# names (Sam's Club, Baker's) that a ConvertTo-Json round trip rewrites, and a 584 KB reserialize is a
# diff nobody can review. Each row is located by its OWN id line and brace-walked, so a nested array or
# an escaped brace inside a product name cannot slide the boundary.
if ($Replace) {
  $newRaw = $raw
  foreach ($b in $built.ToArray()) {
    $idPat = '"id":\s*"' + [regex]::Escape([string]$b.id) + '"'
    $ms = [regex]::Matches($newRaw, $idPat)
    if ($ms.Count -ne 1) { Die ("expected exactly one '" + $b.id + "' id line in the board, found " + $ms.Count + '; refusing to guess which.') }
    $start = $newRaw.LastIndexOf('{', $ms[0].Index)
    if ($start -lt 0) { Die ('could not find the opening brace of ' + $b.id) }
    $depth = 0; $end = -1
    for ($i = $start; $i -lt $newRaw.Length; $i++) {
      $ch = $newRaw[$i]
      if ($ch -eq '"') { $i++; while ($i -lt $newRaw.Length -and $newRaw[$i] -ne '"') { if ($newRaw[$i] -eq '\') { $i++ }; $i++ }; continue }
      if ($ch -eq '{') { $depth++ } elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
    }
    if ($end -lt 0) { Die ('could not find the closing brace of ' + $b.id) }
    # match the indent of the row being replaced, so the diff shows a changed row and not a reflow
    $lineStart = $newRaw.LastIndexOf("`n", $start)
    $indent = if ($lineStart -ge 0) { ($newRaw.Substring($lineStart + 1, $start - $lineStart - 1)) } else { '        ' }
    $j = ($b | ConvertTo-Json -Depth 8)
    $blockText = (($j -split "`r?`n" | ForEach-Object { $indent + $_ }) -join "`r`n").TrimStart()
    $newRaw = $newRaw.Substring(0, $start) + $blockText + $newRaw.Substring($end + 1)
  }
}
else {

# ---- append as TEXT, immediately before the closing bracket of the comparison array ------------------------
$blocks = @()
foreach ($b in $built.ToArray()) {
  $j = ($b | ConvertTo-Json -Depth 8)
  $blocks += (($j -split "`r?`n" | ForEach-Object { '        ' + $_ }) -join "`r`n")
}
# find the comparison array's closing bracket: the last ']' that precedes the file's final '}'
$closeObj = $raw.LastIndexOf('}')
if ($closeObj -lt 0) { Die 'could not find the end of the board document' }
$closeArr = $raw.LastIndexOf(']', $closeObj)
if ($closeArr -lt 0) { Die 'could not find the end of the comparison array' }
$newRaw = $raw.Substring(0, $closeArr).TrimEnd() + ",`r`n" + ($blocks -join ",`r`n") + "`r`n    " + $raw.Substring($closeArr)
}

# ---- prove it ---------------------------------------------------------------------------------------------
$after = $null
try { $after = $newRaw | ConvertFrom-Json } catch { Die ('the edit produced invalid JSON, nothing written: ' + $_.Exception.Message) }
$aList = New-Object System.Collections.ArrayList
foreach ($r in @($after.comparison)) { [void]$aList.Add($r) }
# A REPLACE MUST NOT CHANGE THE COUNT, and an append must change it by exactly the rows offered. Same
# proof, two shapes: a replace that dropped a row and an append that lost one both land here.
$wantCount = if ($Replace) { $bList.Count } else { $bList.Count + @($built).Count }
if ($aList.Count -ne $wantCount) { Die ('row count went ' + $bList.Count + ' -> ' + $aList.Count + ', expected ' + $wantCount + '; refusing.') }
$replacing = @{}
if ($Replace) { foreach ($b in $built.ToArray()) { $replacing[[string]$b.id] = $true } }
$collateral = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $bList.Count; $i++) {
  # THE REPLACED ROWS ARE THE ONLY ONES THAT MAY MOVE. Every other row must still serialize
  # byte-identically, which is the whole reason this file is edited as text.
  if ($replacing.ContainsKey([string]$bList[$i].id)) { continue }
  $bs = ($bList[$i] | ConvertTo-Json -Depth 10 -Compress)
  $as = ($aList[$i] | ConvertTo-Json -Depth 10 -Compress)
  if ($bs -ne $as) { [void]$collateral.Add([string]$bList[$i].id) }
}
# ...and a replace must actually CHANGE the rows it names. A no-op that reports success is how a
# board keeps a wrong price through a run that claimed to fix it.
if ($Replace) {
  $unchanged = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $bList.Count; $i++) {
    if (-not $replacing.ContainsKey([string]$bList[$i].id)) { continue }
    if (($bList[$i] | ConvertTo-Json -Depth 10 -Compress) -eq ($aList[$i] | ConvertTo-Json -Depth 10 -Compress)) { [void]$unchanged.Add([string]$bList[$i].id) }
  }
  if ($unchanged.Count -gt 0) { Die ('-Replace changed NOTHING on ' + $unchanged.Count + ' named row(s) (' + ((@($unchanged.ToArray()) | Select-Object -First 5) -join ', ') + '). Refusing to report a rewrite that did not happen.') }
}
if ($collateral.Count -gt 0) { Die ('COLLATERAL DAMAGE: ' + $collateral.Count + ' existing row(s) changed (' + ((@($collateral.ToArray()) | Select-Object -First 5) -join ', ') + '). Nothing written.') }
Say ('    ' + $bList.Count + ' -> ' + $aList.Count + ' rows, 0 collateral changes, JSON re-parsed clean' + $(if ($Replace) { ' (' + @($built).Count + ' row(s) REPLACED)' } else { '' }))

if (-not $Apply) { Say '    DRY RUN - nothing written. Re-run with -Apply.'; exit 0 }
[IO.File]::WriteAllText($BoardFile, $newRaw, (New-Object System.Text.UTF8Encoding($false)))
Say ('    wrote ' + $BoardFile)
Say '    NEXT: recipe-overlay.ps1 -> export-feed.ps1, then re-check the bids on the feed.'
if ($Replace) {
  Say '    AND: if any replaced id has a recipe-floor-id-map.json entry, DROP IT - derive-recipe-floors'
  Say '         refreshes a mapped row from its weekly twin and will stamp these cells straight back over.'
}
exit 0
