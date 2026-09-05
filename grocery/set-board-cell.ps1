<#
  set-board-cell.ps1 - correct ONE store cell on ONE existing row of out\recipe-board-everyday.json.

  WHY THIS EXISTS. A cell can carry a perfectly current price for something that is not the ingredient.
  Walmart provolone held Sargento SMOKED at $0.405/oz on a row whose Aldi cell says "Non Smoked"; Family
  Fare smoked-paprika claimed a 7 oz size that line has never sold, was 2.5x cheap, and was the CROWN.
  That class is not stale pricing and none of the existing tools could fix it:

    add-recipe-board-rows.ps1 -Replace   rewrites a WHOLE row and demands item+size+price on EVERY cell.
                                         183 rows carry cells that are per_unit ONLY - no item, no size -
                                         and those cells DO reach smp-feed.json and are shown to shoppers.
                                         A -Replace to fix one cell silently DROPS every one of them.
    board-price-overrides.json           its own readme excludes wrong-product/name-drift BY DESIGN: an
                                         override pins a PRICE and the card still names the wrong product.
    relink-drifted-cells.ps1             fixes the LINK to match the board. That is the opposite direction.

  So the wrong-product fix was being done by hand with text surgery (commit edeaa5f2). This is that edit,
  gated: one cell moves, every other cell and every other row is proved byte-identical, and the incomplete
  cells that -Replace would have eaten are asserted present BY NAME on the way out.

  THE MAIN WEEKLY BOARD IS NOT EDITABLE HERE, and that is deliberate. comparison-*.json is rebuilt from the
  captures every morning, so an edit to it is erased by the next run. A wrong product on the weekly board is
  ruled with add-known-wrong.ps1, which compare-deals reads and enforces on every build. This file is only
  for recipe-board-everyday.json, whose rows are hand-held and have no other author.

  Usage:
    .\set-board-cell.ps1 -Id provolone-cheese -Store "Sam's Club" -Remove `
        -Evidence "Sam's carries no non-smoked sliced provolone; only the smoked 2 lb and a 14 lb horn."
    .\set-board-cell.ps1 -Id honey-dijon-mustard -Store "Family Fare" `
        -Item "Our Family Mustard, Honey 12 Oz" -Size "12 oz" -Price 2.19 -Evidence "..." -Apply
    .\set-board-cell.ps1 -SelfTest

  Exit 0 = written (or dry run clean). Exit 1 = refused, nothing written.
#>
param(
  [string]$Id = '',
  [string]$Store = '',
  [string]$Item = '',
  [string]$Size = '',
  [double]$Price = 0,
  [string]$Evidence = '',
  [switch]$Remove,
  [switch]$AllowCrownChange,
  [string]$BoardFile = '',
  [switch]$Apply,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $BoardFile) { $BoardFile = Join-Path $root 'out\recipe-board-everyday.json' }
function Say([string]$s) { Write-Output $s }
function Die([string]$s) { Write-Output ('set-board-cell: ' + $s); exit 1 }

# The seven Omaha stores, spelled exactly as every board row and capture spells them.
$STORES = @("Baker's", 'Family Fare', 'Hy-Vee', 'Aldi', 'Fareway', "Sam's Club", 'Walmart')

# ---- size -> magnitude in the ROW'S unit ------------------------------------------------------------------
# MIRRORED, NOT SHARED. export-feed.ps1 owns the published copy and add-recipe-board-rows.ps1 carries the
# second; this is the third. They must agree or the feed re-derives a different package basis from the same
# string. Dot-sourcing add-recipe-board-rows is not an option - it runs its whole write road on load.
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
    # On a row already established as a liquid, a package labelled "32 oz" is 32 FLUID ounces. This one
    # direction only; every other weight/volume crossing is refused, because guessing one is a wrong price.
    'oz>floz'  { return $mag }
    default    { return 0 }
  }
}
function Resolve-Size([string]$size, [string]$rowUnit) {
  # Returns magnitude in $rowUnit, or 0 when it cannot be proven.
  $s = ([string]$size).Trim()
  if (-not $s) { return 0 }
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

# A store name is written into this file with ' for the apostrophe (Sam's Club, Baker's), which is the
# whole reason the file is edited as text rather than reserialized. Any search of the RAW text has to look
# for the escaped spelling, not the readable one.
function Get-JsonToken([string]$s) { return ($s -replace "'", '\u0027') }

# Find the object block that starts at or before $at, by walking braces from its opening '{'. String bodies
# are skipped so a brace inside a product name cannot slide the boundary.
function Get-Block([string]$text, [int]$at) {
  $start = $text.LastIndexOf('{', $at)
  if ($start -lt 0) { return $null }
  $depth = 0; $end = -1
  for ($i = $start; $i -lt $text.Length; $i++) {
    $ch = $text[$i]
    if ($ch -eq '"') { $i++; while ($i -lt $text.Length -and $text[$i] -ne '"') { if ($text[$i] -eq '\') { $i++ }; $i++ }; continue }
    if ($ch -eq '{') { $depth++ } elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
  }
  if ($end -lt 0) { return $null }
  return @{ start = $start; end = $end }
}

# ---- SELF-TEST -------------------------------------------------------------------------------------------
if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) { if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ } }

  T 'plain oz size resolves on an oz row'        ([math]::Abs((Resolve-Size '12 oz' 'oz') - 12) -lt 1e-9) ([string](Resolve-Size '12 oz' 'oz'))
  T 'lb size converts onto an oz row'            ([math]::Abs((Resolve-Size '2 lb' 'oz') - 32) -lt 1e-6) ([string](Resolve-Size '2 lb' 'oz'))
  T 'a bare each on an each row is one unit'     ([math]::Abs((Resolve-Size 'each' 'each') - 1) -lt 1e-9) ([string](Resolve-Size 'each' 'each'))
  T 'MUST FIRE  grams on an each row is refused' ((Resolve-Size '588 g' 'each') -eq 0) ([string](Resolve-Size '588 g' 'each'))
  T 'MUST FIRE  an unparseable size is refused'  ((Resolve-Size 'per lb marker' 'oz') -eq 0) ([string](Resolve-Size 'per lb marker' 'oz'))
  T "apostrophe store token is escaped"          ((Get-JsonToken "Sam's Club") -eq 'Sam\u0027s Club') (Get-JsonToken "Sam's Club")

  $rt = Join-Path ([IO.Path]::GetTempPath()) ('sbc-' + [guid]::NewGuid().ToString('N'))
  [void](New-Item -ItemType Directory -Path $rt)
  try {
    # The scratch board mirrors the real one's two load-bearing shapes: a target row that carries BOTH
    # named cells and per_unit-ONLY cells, and 120 filler rows so the >=100 parse guard is satisfied.
    $fill = @()
    for ($i = 1; $i -le 120; $i++) {
      $fill += [ordered]@{ id = ('filler-' + $i); commodity = ('Filler ' + $i); category = 'Dairy & Eggs'
                           unit = 'oz'; cheapest_store = 'Aldi'
                           stores = @([ordered]@{ store = 'Aldi'; per_unit = 1.0; type = 'everyday'; bulk = $false
                                                  item = ('Thing ' + $i); size = '8 oz' }) }
    }
    # cheapest is Aldi at 0.10 and Aldi is a per_unit-ONLY cell - the exact shape -Replace destroys.
    $fill += [ordered]@{ id = 'target-mustard'; commodity = 'Target Mustard'; category = 'Sauces & Condiments'
                         unit = 'oz'; cheapest_store = 'Aldi'
                         stores = @(
                           [ordered]@{ store = 'Aldi'; per_unit = 0.10; type = 'everyday'; bulk = $false },
                           [ordered]@{ store = "Sam's Club"; per_unit = 0.20; type = 'everyday'; bulk = $true
                                       item = 'WRONG PRODUCT'; size = '2 lb' },
                           [ordered]@{ store = "Baker's"; per_unit = 0.30; type = 'everyday'; bulk = $false },
                           [ordered]@{ store = 'Walmart'; per_unit = 0.40; type = 'everyday'; bulk = $false
                                       item = 'Great Value Mustard'; size = '12 oz' }) }
    $bf = Join-Path $rt 'board.json'
    [IO.File]::WriteAllText($bf, (ConvertTo-Json @{ week_of = '2026-08-29'; comparison = $fill } -Depth 9), (New-Object System.Text.UTF8Encoding($false)))
    $pristine = Get-Content $bf -Raw

    function Board { (Read-JsonFile $bf).comparison }
    function Row([string]$id) { @(Board) | Where-Object { $_.id -eq $id } }
    function Cell([string]$id, [string]$st) { @((Row $id).stores) | Where-Object { $_.store -eq $st } }
    # HASHTABLE SPLAT, NOT AN ARRAY ONE - an array splat binds POSITIONALLY, so '-Id' arrives as the VALUE
    # of $Id and a case that meant to assert a refusal goes green on the wrong error.
    function Run([hashtable]$p) { $o = & $PSCommandPath @p; return @{ rc = $LASTEXITCODE; out = ($o -join ' | ') } }
    $EV = 'self-test evidence, long enough to pass the gate'

    # ---- the happy path -----------------------------------------------------------------------------
    $r = Run @{ Id = 'target-mustard'; Store = 'Walmart'; Item = 'RIGHT PRODUCT'; Size = '12 oz'; Price = 2.4
                Evidence = $EV; BoardFile = $bf; Apply = $true }
    T 'sets the named cell'                      ($r.rc -eq 0 -and [string](Cell 'target-mustard' 'Walmart').item -eq 'RIGHT PRODUCT' -and [double](Cell 'target-mustard' 'Walmart').per_unit -eq 0.2) $r.out
    T '  ...row count does not move'             (@(Board).Count -eq 121) (@(Board).Count.ToString())
    T '  ...cell count on the row does not move' (@((Row 'target-mustard').stores).Count -eq 4) (@((Row 'target-mustard').stores).Count.ToString())
    T '  ...no other row changed'                ([string](Row 'filler-7').stores[0].item -eq 'Thing 7' -and [string](Row 'filler-120').stores[0].item -eq 'Thing 120') 'a filler row moved'
    # THE POINT OF THE WHOLE FILE: the incomplete cells are still here, still incomplete, untouched.
    $aldi = Cell 'target-mustard' 'Aldi'; $bak = Cell 'target-mustard' "Baker's"
    T '  ...the per_unit-ONLY Aldi cell SURVIVED' ($null -ne $aldi -and [double]$aldi.per_unit -eq 0.10 -and -not $aldi.PSObject.Properties['item'] -and -not $aldi.PSObject.Properties['size']) 'Aldi cell was eaten or grew fields'
    T "  ...the per_unit-ONLY Baker's cell SURVIVED" ($null -ne $bak -and [double]$bak.per_unit -eq 0.30 -and -not $bak.PSObject.Properties['item']) "Baker's cell was eaten"
    T '  ...the untouched named cell is byte-identical' ([string](Cell 'target-mustard' "Sam's Club").item -eq 'WRONG PRODUCT') "Sam's cell moved"

    # ---- refusals -----------------------------------------------------------------------------------
    $r = Run @{ Id = 'no-such-row'; Store = 'Walmart'; Item = 'X'; Size = '12 oz'; Price = 1; Evidence = $EV; BoardFile = $bf; Apply = $true }
    T 'MUST FIRE  an id with no row is refused'  ($r.rc -ne 0 -and @(Board).Count -eq 121) $r.out

    $r = Run @{ Id = 'target-mustard'; Store = 'Fareway'; Item = 'X'; Size = '12 oz'; Price = 1; Evidence = $EV; BoardFile = $bf; Apply = $true }
    T 'MUST FIRE  a store with no cell on the row is refused' ($r.rc -ne 0 -and @((Row 'target-mustard').stores).Count -eq 4) $r.out

    $r = Run @{ Id = 'target-mustard'; Store = 'Walmart'; Item = 'Y'; Size = 'per lb marker'; Price = 1; Evidence = $EV; BoardFile = $bf; Apply = $true }
    T 'MUST FIRE  a size that will not resolve is refused' ($r.rc -ne 0 -and [string](Cell 'target-mustard' 'Walmart').item -eq 'RIGHT PRODUCT') $r.out

    $r = Run @{ Id = 'target-mustard'; Store = 'Walmart'; Item = 'RIGHT PRODUCT'; Size = '12 oz'; Price = 2.4; Evidence = $EV; BoardFile = $bf; Apply = $true }
    T 'MUST FIRE  an edit that changes NOTHING is refused' ($r.rc -ne 0 -and $r.out -match 'changed NOTHING') $r.out

    $r = Run @{ Id = 'target-mustard'; Store = 'Walmart'; Item = 'Z'; Size = '12 oz'; Price = 2.4; Evidence = 'too short'; BoardFile = $bf; Apply = $true }
    T 'MUST FIRE  a run with no real evidence is refused' ($r.rc -ne 0 -and $r.out -match 'Evidence') $r.out

    # A cell that undercuts the crown changes who wins the row. That is a bigger claim than "this cell was
    # the wrong product" and it must be said out loud, not slipped in.
    $r = Run @{ Id = 'target-mustard'; Store = 'Walmart'; Item = 'Cheap'; Size = '12 oz'; Price = 0.24; Evidence = $EV; BoardFile = $bf; Apply = $true }
    T 'MUST FIRE  a crown change without -AllowCrownChange is refused' ($r.rc -ne 0 -and $r.out -match 'crown') $r.out
    T '  ...and the board did not move'          ([string](Cell 'target-mustard' 'Walmart').item -eq 'RIGHT PRODUCT') 'the crown-change run wrote anyway'

    $r = Run @{ Id = 'target-mustard'; Store = 'Walmart'; Item = 'Cheap'; Size = '12 oz'; Price = 0.24; Evidence = $EV; BoardFile = $bf; Apply = $true; AllowCrownChange = $true }
    T '-AllowCrownChange lets it through and moves cheapest_store' ($r.rc -eq 0 -and [string](Row 'target-mustard').cheapest_store -eq 'Walmart') $r.out

    # ---- -Remove ------------------------------------------------------------------------------------
    [IO.File]::WriteAllText($bf, $pristine, (New-Object System.Text.UTF8Encoding($false)))
    $r = Run @{ Id = 'target-mustard'; Store = "Sam's Club"; Remove = $true; Evidence = $EV; BoardFile = $bf; Apply = $true }
    T '-Remove drops exactly one cell'            ($r.rc -eq 0 -and @((Row 'target-mustard').stores).Count -eq 3 -and $null -eq (Cell 'target-mustard' "Sam's Club")) $r.out
    T '  ...and the escaped-apostrophe store was the one that went' ($null -ne (Cell 'target-mustard' 'Walmart') -and $null -ne (Cell 'target-mustard' 'Aldi')) 'removed the wrong cell'
    T '  ...and the per_unit-ONLY cells still survive' ($null -ne (Cell 'target-mustard' 'Aldi') -and $null -ne (Cell 'target-mustard' "Baker's")) 'an incomplete cell went with it'
    T '  ...and no other row moved'               (@(Board).Count -eq 121 -and [string](Row 'filler-42').stores[0].item -eq 'Thing 42') 'collateral'

    $r = Run @{ Id = 'target-mustard'; Store = "Sam's Club"; Remove = $true; Evidence = $EV; BoardFile = $bf; Apply = $true }
    T 'MUST FIRE  removing a cell that is not there is refused' ($r.rc -ne 0) $r.out

    # ---- dry run ------------------------------------------------------------------------------------
    [IO.File]::WriteAllText($bf, $pristine, (New-Object System.Text.UTF8Encoding($false)))
    $b4 = Get-Content $bf -Raw
    $r = Run @{ Id = 'target-mustard'; Store = 'Walmart'; Item = 'DRYRUN'; Size = '12 oz'; Price = 3; Evidence = $EV; BoardFile = $bf }
    T 'CLEAN TWIN a run without -Apply writes nothing' ($r.rc -eq 0 -and (Get-Content $bf -Raw) -eq $b4) $r.out
  } finally { Remove-Item -Recurse -Force $rt -ErrorAction SilentlyContinue }

  if ($bad) { Write-Output ("set-board-cell SELF-TEST FAIL ({0})" -f $bad); exit 1 }
  Write-Output 'set-board-cell SELF-TEST PASS'; exit 0
}

# ---- real run --------------------------------------------------------------------------------------------
if (-not $Id)    { Die 'pass -Id <row id> (or -SelfTest). An empty run would prove nothing.' }
if (-not $Store) { Die 'pass -Store <store>' }
if ($STORES -notcontains $Store) { Die ("unknown store '" + $Store + "' - must be spelled exactly as the boards spell it: " + ($STORES -join ', ')) }
if (([string]$Evidence).Trim().Length -lt 20) { Die '-Evidence is required and must actually say why (>= 20 chars). A cell rewritten without a reason is indistinguishable from a typo.' }
if (-not $Remove) {
  if (-not $Item)   { Die '-Item is required (or pass -Remove). Identity travels with the price or not at all.' }
  if (-not $Size)   { Die '-Size is required (or pass -Remove).' }
  if ($Price -le 0) { Die '-Price is required and must be > 0 (or pass -Remove).' }
}
if (-not (Test-Path $BoardFile)) { Die ('board file not found: ' + $BoardFile) }

$raw = [IO.File]::ReadAllText($BoardFile, [Text.Encoding]::UTF8) -replace '^\xEF\xBB\xBF', ''
$before = $raw | ConvertFrom-Json
$bList = New-Object System.Collections.ArrayList
foreach ($r in @($before.comparison)) { [void]$bList.Add($r) }
if ($bList.Count -lt 100) { Die ('parsed only ' + $bList.Count + ' board rows - implausible for this file; parse error, not data. Nothing written.') }

$rowIdx = -1
for ($i = 0; $i -lt $bList.Count; $i++) { if ([string]$bList[$i].id -eq $Id) { $rowIdx = $i; break } }
if ($rowIdx -lt 0) { Die ("no row with id '" + $Id + "' in " + (Split-Path -Leaf $BoardFile) + '.') }
$row = $bList[$rowIdx]
$unit = [string]$row.unit
$cells = @($row.stores)
$cellIdx = -1
for ($i = 0; $i -lt $cells.Count; $i++) { if ([string]$cells[$i].store -eq $Store) { $cellIdx = $i; break } }
if ($cellIdx -lt 0) { Die ("row '" + $Id + "' has no " + $Store + " cell. This tool corrects a cell that exists; it does not add one.") }

# The incomplete cells, named NOW, so the proof at the bottom can assert each one by name rather than by
# a count that a replacement could satisfy while dropping the very cells this file exists to protect.
$incomplete = @()
foreach ($c in $cells) {
  if ([string]$c.store -eq $Store) { continue }
  if (-not $c.PSObject.Properties['item'] -or -not ([string]$c.item) -or -not $c.PSObject.Properties['size'] -or -not ([string]$c.size)) {
    $incomplete += [string]$c.store
  }
}

Say ('set-board-cell: ' + $Id + ' [' + $unit + '] / ' + $Store)
Say ('  was : per_unit=' + [string]$cells[$cellIdx].per_unit + '  size=' + [string]$cells[$cellIdx].size + '  ' + [string]$cells[$cellIdx].item)
$newPu = 0.0
if (-not $Remove) {
  $mag = Resolve-Size $Size $unit
  if ($mag -le 0) { Die ("cannot resolve size '" + $Size + "' into " + $unit + " on " + $Id + " - refusing rather than guessing a basis") }
  $newPu = [math]::Round($Price / $mag, 4)
  Say ('  now : per_unit=' + [string]$newPu + '  size=' + $Size + '  ' + $Item + '   ($' + [string]$Price + ' / ' + [string]$mag + ' ' + $unit + ')')
} else {
  Say ('  now : REMOVED - ' + $Store + ' does not carry this commodity')
}
if ($incomplete.Count -gt 0) { Say ('  incomplete cells on this row that MUST survive: ' + ($incomplete -join ', ')) }
Say ('  why : ' + $Evidence)

# ---- who wins the row, before and after -------------------------------------------------------------------
function Get-Cheapest($cellList, [string]$skipStore, [string]$setStore, [double]$setPu) {
  $best = $null; $bestPu = [double]::MaxValue
  foreach ($c in $cellList) {
    $st = [string]$c.store
    if ($skipStore -and $st -eq $skipStore) { continue }
    $pu = if ($setStore -and $st -eq $setStore) { $setPu } else { [double]$c.per_unit }
    if ($pu -gt 0 -and $pu -lt $bestPu) { $bestPu = $pu; $best = $st }
  }
  return @{ store = $best; pu = $bestPu }
}
$wasWin = Get-Cheapest $cells '' '' 0
$nowWin = if ($Remove) { Get-Cheapest $cells $Store '' 0 } else { Get-Cheapest $cells '' $Store $newPu }
$crownMoved = ([string]$wasWin.store -ne [string]$nowWin.store)
if ($crownMoved) {
  Say ('  CROWN MOVES: ' + [string]$wasWin.store + ' @ ' + [string]$wasWin.pu + '  ->  ' + [string]$nowWin.store + ' @ ' + [string]$nowWin.pu)
  if (-not $AllowCrownChange) {
    Die ('this edit changes the crown on ' + $Id + ' (' + [string]$wasWin.store + ' -> ' + [string]$nowWin.store + '). That is a bigger claim than "this cell named the wrong product" and it moves what shoppers are sent to. Re-run with -AllowCrownChange if that is what the evidence says.')
  }
}

# ---- text surgery: locate the row block, then the ONE cell inside it ---------------------------------------
$idPat = '"id":\s*"' + [regex]::Escape($Id) + '"'
$ms = [regex]::Matches($raw, $idPat)
if ($ms.Count -ne 1) { Die ("expected exactly one '" + $Id + "' id line in the board, found " + $ms.Count + '; refusing to guess which.') }
$rowBlk = Get-Block $raw $ms[0].Index
if ($null -eq $rowBlk) { Die ('could not brace-walk the row block for ' + $Id) }
$rowText = $raw.Substring($rowBlk.start, $rowBlk.end - $rowBlk.start + 1)

$stTok = '"store":\s*"' + [regex]::Escape((Get-JsonToken $Store)) + '"'
$cms = [regex]::Matches($rowText, $stTok)
if ($cms.Count -ne 1) { Die ("expected exactly one " + $Store + " cell inside row '" + $Id + "', found " + $cms.Count + '; refusing to guess which.') }
$cellBlk = Get-Block $rowText $cms[0].Index
if ($null -eq $cellBlk) { Die ('could not brace-walk the ' + $Store + ' cell block') }

if ($Remove) {
  # Take the cell WITH its separating comma, so the array stays well-formed whichever end it sits at.
  $s = $cellBlk.start; $e = $cellBlk.end
  $pre = $rowText.Substring(0, $s)
  $post = $rowText.Substring($e + 1)
  if ($post -match '^\s*,') {                       # not the last cell: eat the comma that follows
    $post = $post -replace '^\s*,', ''
    $newRowText = ($pre.TrimEnd() -replace ',\s*$', ',') + $post.TrimStart("`r","`n")
    # re-indent: keep the leading whitespace that belonged to the removed cell
    $lead = [regex]::Match($pre, '(\r?\n[ \t]*)$').Groups[1].Value
    $newRowText = $pre.Substring(0, $pre.Length - $lead.Length) + $lead + $post.TrimStart("`r","`n"," ","`t")
  } else {                                          # last cell: eat the comma that PRECEDES it
    $pre2 = $pre -replace ',\s*$', ''
    $newRowText = $pre2 + $post
  }
} else {
  # Preserve every key the cell already carries (type, bulk, membership, unit, ...) and its key ORDER;
  # only the three that describe WHICH PRODUCT this is are allowed to move.
  $cellObj = $cells[$cellIdx] | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $cellObj.per_unit = $newPu
  if ($cellObj.PSObject.Properties['item']) { $cellObj.item = $Item } else { Add-Member -InputObject $cellObj -NotePropertyName 'item' -NotePropertyValue $Item }
  if ($cellObj.PSObject.Properties['size']) { $cellObj.size = $Size } else { Add-Member -InputObject $cellObj -NotePropertyName 'size' -NotePropertyValue $Size }
  $lineStart = $rowText.LastIndexOf("`n", $cellBlk.start)
  $indent = if ($lineStart -ge 0) { $rowText.Substring($lineStart + 1, $cellBlk.start - $lineStart - 1) } else { '        ' }
  $j = ($cellObj | ConvertTo-Json -Depth 8)
  $blockText = (($j -split "`r?`n" | ForEach-Object { $indent + $_ }) -join "`r`n").TrimStart()
  $newRowText = $rowText.Substring(0, $cellBlk.start) + $blockText + $rowText.Substring($cellBlk.end + 1)
}

# cheapest_store lives on the ROW, so it is a second, separate edit inside the same block - and only when
# the crown actually moved. Leaving it alone otherwise is what keeps the diff to the one cell.
if ($crownMoved) {
  $cs = '"cheapest_store":\s*"[^"]*"'
  if ([regex]::Matches($newRowText, $cs).Count -eq 1) {
    $newRowText = [regex]::Replace($newRowText, $cs, '"cheapest_store": "' + (Get-JsonToken ([string]$nowWin.store)) + '"')
  }
  $cp = '"cheapest_price":\s*[0-9.]+'
  if ([regex]::Matches($newRowText, $cp).Count -eq 1) {
    $newRowText = [regex]::Replace($newRowText, $cp, '"cheapest_price": ' + [string][math]::Round([double]$nowWin.pu, 4))
  }
}

$newRaw = $raw.Substring(0, $rowBlk.start) + $newRowText + $raw.Substring($rowBlk.end + 1)

# ---- prove it ---------------------------------------------------------------------------------------------
$after = $null
try { $after = $newRaw | ConvertFrom-Json } catch { Die ('the edit produced invalid JSON, nothing written: ' + $_.Exception.Message) }
$aList = New-Object System.Collections.ArrayList
foreach ($r in @($after.comparison)) { [void]$aList.Add($r) }
if ($aList.Count -ne $bList.Count) { Die ('row count went ' + $bList.Count + ' -> ' + $aList.Count + '; refusing.') }

# 1. every OTHER row byte-identical
$collateral = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $bList.Count; $i++) {
  if ($i -eq $rowIdx) { continue }
  if (($bList[$i] | ConvertTo-Json -Depth 10 -Compress) -ne ($aList[$i] | ConvertTo-Json -Depth 10 -Compress)) { [void]$collateral.Add([string]$bList[$i].id) }
}
if ($collateral.Count -gt 0) { Die ('COLLATERAL DAMAGE: ' + $collateral.Count + ' other row(s) changed (' + ((@($collateral.ToArray()) | Select-Object -First 5) -join ', ') + '). Nothing written.') }

# 2. cell count moved by exactly what was asked
$aCells = @($aList[$rowIdx].stores)
$wantCells = if ($Remove) { $cells.Count - 1 } else { $cells.Count }
if ($aCells.Count -ne $wantCells) { Die ('cell count on ' + $Id + ' went ' + $cells.Count + ' -> ' + $aCells.Count + ', expected ' + $wantCells + '; refusing.') }

# 3. every OTHER cell on the target row byte-identical
$cellCollateral = New-Object System.Collections.ArrayList
foreach ($bc in $cells) {
  $st = [string]$bc.store
  if ($st -eq $Store) { continue }
  $ac = $aCells | Where-Object { [string]$_.store -eq $st } | Select-Object -First 1
  if ($null -eq $ac) { [void]$cellCollateral.Add($st + ' (VANISHED)'); continue }
  if (($bc | ConvertTo-Json -Depth 10 -Compress) -ne ($ac | ConvertTo-Json -Depth 10 -Compress)) { [void]$cellCollateral.Add($st) }
}
if ($cellCollateral.Count -gt 0) { Die ('COLLATERAL DAMAGE inside ' + $Id + ': ' + $cellCollateral.Count + ' sibling cell(s) changed (' + ($cellCollateral.ToArray() -join ', ') + '). Nothing written.') }

# 4. THE INCOMPLETE CELLS, BY NAME. A count would be satisfied by a replacement; only naming them catches
#    the -Replace failure mode this file was written to end.
foreach ($st in $incomplete) {
  $ac = $aCells | Where-Object { [string]$_.store -eq $st } | Select-Object -First 1
  if ($null -eq $ac) { Die ('the incomplete ' + $st + ' cell on ' + $Id + ' was DROPPED by this edit. That is the exact defect this tool exists to prevent. Nothing written.') }
  if ($ac.PSObject.Properties['item'] -and [string]$ac.item) { Die ('the incomplete ' + $st + ' cell on ' + $Id + ' grew an invented item name. Nothing written.') }
}

# 5. the named cell actually changed
$targetAfter = $aCells | Where-Object { [string]$_.store -eq $Store } | Select-Object -First 1
if ($Remove) {
  if ($null -ne $targetAfter) { Die ('-Remove left the ' + $Store + ' cell in place. Nothing written.') }
} else {
  if ($null -eq $targetAfter) { Die ('the ' + $Store + ' cell vanished. Nothing written.') }
  if (($cells[$cellIdx] | ConvertTo-Json -Depth 10 -Compress) -eq ($targetAfter | ConvertTo-Json -Depth 10 -Compress)) {
    Die ('this edit changed NOTHING on ' + $Id + '/' + $Store + '. Refusing to report a correction that did not happen.')
  }
}

Say ('    ' + $bList.Count + ' rows unchanged, ' + $cells.Count + ' -> ' + $aCells.Count + ' cells on ' + $Id + ', 0 collateral, ' + $incomplete.Count + ' incomplete cell(s) proved present by name, JSON re-parsed clean')
if (-not $Apply) { Say '    DRY RUN - nothing written. Re-run with -Apply.'; exit 0 }
[IO.File]::WriteAllText($BoardFile, $newRaw, (New-Object System.Text.UTF8Encoding($false)))
Say ('    wrote ' + $BoardFile)
Say '    NEXT: recipe-overlay.ps1 -> export-feed.ps1 -> cost-recipes.ps1'
Say ('    AND: check recipe-floor-id-map.json for ' + $Id + ' - derive-recipe-floors will stamp a mapped row straight back over.')
exit 0
