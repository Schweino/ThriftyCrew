<#
  add-ingredient-row.ps1 - append a NEW row to meal-prep\db\ingredients.json, the ingredient vocabulary.

  WHY THIS EXISTS (2026-08-16). design\PLAN-ingredient-vocabulary-2026-08-16.md section 1 names three id
  namespaces and says the ingredient-row layer is governed by "nobody - the gap". The tooling matched that:
  ingredient-vocab.ps1 only READS the vocabulary, and rebid-ingredient.ps1 only RE-POINTS a row that already
  exists. Extending the vocabulary - the act the plan calls "a deliberate, recorded act" - had no gated path
  at all, exactly as grocery\out\recipe-board-everyday.json had none until add-recipe-board-rows.ps1. This is
  that path for the ingredient layer.

  IT DOES NOT MINT A COMMODITY. -Bid must already be a priced id on the live feed. Deciding that a food needs
  a NEW commodity id is the commodity-registrar's ruling and new-commodity.ps1's job; this script only points
  a vocabulary name at an id that is already there. A dangling bid is the failure it refuses hardest.

  SAME SAFETY CONTRACT AS add-recipe-board-rows.ps1 / new-commodity.ps1: text-level append, never a whole-file
  reserialize; re-parse before writing; row count must go up by exactly one; every PRE-EXISTING row proved
  byte-identical (with one declared, proved exception - see -DropAliasFrom); BOM-less write; and a plausibility
  floor that refuses to act on an implausibly small parse, because the 2026-08-16 incident began with a tool
  reading 301 rows as 8 and being believed.

  -DropAliasFrom EXISTS BECAUSE THE TWO ACTS ARE ONE ACT. Adding a row named X while some other row still
  claims X as an alias is a collision - two rows answering one name, which V2 of the plan says must refuse at
  write. When a new row SUPERSEDES an alias (fresh Broccoli superseding "Broccoli" -> frozen Broccoli Florets),
  the alias must come off in the same edit or the file is briefly, then permanently, ambiguous. The drop is
  proved as narrowly as the append: that row may differ from its old self in the alias list and the ruling
  string and in nothing else.

  ADDING THE ROW DOES NOT MOVE ANY SPEC. Specs that already cost this food carry the OLD bid inline. After
  this, run:
    rebid-ingredient.ps1 -Item <name> -ToBid <bid> -ToUnit <unit> -ToGpu <gpu> -FromBid <the old bid> -Apply
  then the standard chain: engine\cost-recipes.ps1 -> pipeline\compute-v2-perserving.ps1 ->
  pipeline\regenerate-ingredient-map.ps1 -> pipeline\reanchor-machine-fields.ps1 -Slugs <slugs> ->
  pipeline\db-build.ps1 + audit-schema-constraints.ps1 -> audit-vocab-integrity.ps1.

  Usage:
    .\add-ingredient-row.ps1 -Item 'Broccoli' -Bid broccoli -Unit lb -Gpu 453.592 -BuyPkgG 453.592 -BuyPkgLabel 'lb'
    .\add-ingredient-row.ps1 ... -DropAliasFrom 'Broccoli Florets' -Note '...' -Apply
    .\add-ingredient-row.ps1 -SelfTest

  Exit 0 = written (or dry run clean). Exit 1 = refused, nothing written.
#>
# [CmdletBinding()] IS LOAD-BEARING, NOT DECORATION (2026-08-27). Without it a plain param() block
# SILENTLY SWALLOWS undeclared parameters: -PantryPkgG 737 -PantryPkgLabel '26oz canister' was passed
# to this script, every one of them ignored, and the tool printed its full success banner - "0 collateral
# changes, JSON re-parsed clean" - over a Sea Salt row that had landed with NO package basis at all. A
# gated writer that reports success for an argument it did not honour is worse than one that refuses,
# because the operator has a receipt. With this attribute PowerShell rejects the unknown name outright.
[CmdletBinding()]
param(
  [string]$Item = '',
  [string]$Bid = '',
  [string]$Unit = '',
  [double]$Gpu = 0,
  [double]$BuyPkgG = -1,
  [string]$BuyPkgLabel = '',
  # A PANTRY STAPLE IS A DIFFERENT PURCHASE, and the vocabulary has always said so - Salt carries
  # pantry_pkg_g 737 / '26oz canister' / bulk, not a buy package. The two are not interchangeable:
  # buy_pkg charges the whole package to the recipe, so booking a 24 g salt line against a 737 g
  # canister would add about $2.80 to one recipe for a teaspoon of salt. Only 2 of 308 bid rows carry
  # no package basis at all, so "leave it off" is not the house shape either.
  [double]$PantryPkgG = -1,
  [string]$PantryPkgLabel = '',
  [switch]$Bulk,
  [string]$Board = 'weekly',
  [string[]]$Aliases = @(),
  [string]$Note = '',
  [string]$AliasRuling = '',
  [string]$DropAliasFrom = '',
  [string]$DropAliasRuling = '',
  [string]$IngredientsFile = '',
  [string]$FeedFile = '',
  [switch]$Apply,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
if (-not $IngredientsFile) { $IngredientsFile = Join-Path $mp   'db\ingredients.json' }
if (-not $FeedFile)        { $FeedFile        = Join-Path $repo 'grocery\out\smp-feed.json' }

function Say([string]$s) { Write-Output $s }
function Die([string]$s) { Write-Output ('add-ingredient-row: ' + $s); exit 1 }

# The vocabulary is nowhere near this small. A parse that says otherwise is a broken reader, and a broken
# reader must refuse to testify rather than let a caller append into what it thinks is an 8-row file.
$FLOOR = 200
$UNITS = @('lb', 'oz', 'floz', 'each', 'dozen', 'gallon', 'g')

# Case- and space-insensitive, so 'Baby  Spinach' cannot slip past 'Baby Spinach'. Names are compared this
# way for COLLISION only; the row is always written with the caller's exact spelling.
function Get-NameKey([string]$s) { return (([string]$s) -replace '\s+', ' ').Trim().ToLowerInvariant() }

# Every name a parsed row answers to: its item plus its aliases.
function Get-RowNames($row) {
  $names = @([string]$row.item)
  if ($row.PSObject.Properties['aliases']) { foreach ($a in @($row.aliases)) { $names += [string]$a } }
  return @($names | Where-Object { $_ })
}

if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Say ('  ok    ' + $n) } else { Say ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  T 'name key folds case'            ((Get-NameKey 'Baby Spinach') -eq (Get-NameKey 'baby spinach')) (Get-NameKey 'Baby Spinach')
  T 'name key folds inner whitespace' ((Get-NameKey 'Baby  Spinach') -eq 'baby spinach')             (Get-NameKey 'Baby  Spinach')
  T 'name key trims'                 ((Get-NameKey '  Spinach ') -eq 'spinach')                      (Get-NameKey '  Spinach ')
  $r1 = [pscustomobject]@{ item = 'Broccoli Florets'; aliases = @('Broccoli') }
  $r2 = [pscustomobject]@{ item = 'Salt' }
  T 'row names include aliases'      ((@(Get-RowNames $r1) -join '|') -eq 'Broccoli Florets|Broccoli') ((@(Get-RowNames $r1) -join '|'))
  T 'a row with no aliases is fine'  ((@(Get-RowNames $r2) -join '|') -eq 'Salt')                     ((@(Get-RowNames $r2) -join '|'))
  # MUST FIRE: the collision the plan's V2 says has to refuse at write, in both directions.
  T 'MUST FIRE  new item collides with an existing ALIAS' `
    ((@(Get-RowNames $r1) | ForEach-Object { Get-NameKey $_ }) -contains (Get-NameKey 'broccoli')) 'no collision seen'
  T 'MUST FIRE  new ALIAS collides with an existing item' `
    ((@(Get-RowNames $r1) | ForEach-Object { Get-NameKey $_ }) -contains (Get-NameKey 'Broccoli Florets')) 'no collision seen'
  T 'MUST FIRE  an unrelated name does not collide' `
    (-not ((@(Get-RowNames $r1) | ForEach-Object { Get-NameKey $_ }) -contains (Get-NameKey 'Spinach'))) 'false collision'
  T 'MUST FIRE  the plausibility floor is above a token fixture' ($FLOOR -ge 200) ([string]$FLOOR)
  if ($bad) { Say ("add-ingredient-row SELF-TEST FAIL ({0})" -f $bad); exit 1 }
  Say 'add-ingredient-row SELF-TEST PASS'; exit 0
}

# ---- validate the request --------------------------------------------------------------------------------
if (-not $Item)  { Die 'pass -Item <name> (or -SelfTest)' }
if (-not $Bid)   { Die 'pass -Bid <an id that is ALREADY priced on the feed>' }
if (-not $Unit)  { Die 'pass -Unit <the unit the feed serves that bid in>' }
if ($Gpu -le 0)  { Die 'pass -Gpu <grams in ONE unit of the priced basis> - bid, unit and gpu only mean anything together' }
if ($UNITS -notcontains $Unit) { Die ("bad unit '" + $Unit + "'") }
if ($Board -notin @('weekly', 'recipe')) { Die ("bad board '" + $Board + "' - weekly or recipe") }
if ($Bid -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { Die ("bid '" + $Bid + "' is not a kebab slug") }
if ($DropAliasRuling -and -not $DropAliasFrom) { Die '-DropAliasRuling means nothing without -DropAliasFrom' }

# ---- the bid must already be priced. This script never mints an id. --------------------------------------
if (-not (Test-Path $FeedFile)) { Die ("no feed at " + $FeedFile + " - cannot verify that '" + $Bid + "' is priceable") }
$feed = (Get-Content $FeedFile -Raw -Encoding utf8 | ConvertFrom-Json).ingredients
$fr = $feed.PSObject.Properties[$Bid]
if (-not $fr) { Die ("'" + $Bid + "' is not on the feed - that would be a dangling bid, and the live card would silently show cheapest == everyday. Register and price it first (commodity-registrar, then new-commodity.ps1).") }
$feedUnit = [string]$fr.Value.unit
if ($feedUnit -ne $Unit) { Die ("unit mismatch: the feed serves '" + $Bid + "' per '" + $feedUnit + "', you asked for '" + $Unit + "'. gpu is expressed in the SERVED unit, so this would price the row wrong.") }

# ---- read, with the floor --------------------------------------------------------------------------------
if (-not (Test-Path $IngredientsFile)) { Die ('ingredients file not found: ' + $IngredientsFile) }
$raw = [IO.File]::ReadAllText($IngredientsFile, [Text.Encoding]::UTF8) -replace '^\xEF\xBB\xBF', ''
# ASSIGN THEN WRAP - `@(... | ConvertFrom-Json)` collapses a JSON array to ONE element in PS 5.1, the exact
# marshalling trap that produced the "8 ingredients" reading on 2026-08-16.
$parsed = $raw | ConvertFrom-Json
$before = @($parsed)
if ($before.Count -lt $FLOOR) { Die ('parsed only ' + $before.Count + ' rows from ' + (Split-Path -Leaf $IngredientsFile) + ' - implausibly small for this file; parse error, not data. Nothing written.') }

# ---- collisions, both directions -------------------------------------------------------------------------
# Names claimed by the file today, minus the alias we are about to drop (dropping it is what makes room).
$dropKey = if ($DropAliasFrom) { Get-NameKey $Item } else { '' }
$claimed = @{}
foreach ($r in $before) {
  $owner = [string]$r.item
  foreach ($n in (Get-RowNames $r)) {
    $k = Get-NameKey $n
    if ($DropAliasFrom -and (Get-NameKey $owner) -eq (Get-NameKey $DropAliasFrom) -and $k -eq $dropKey -and (Get-NameKey $n) -ne (Get-NameKey $owner)) { continue }
    $claimed[$k] = $owner
  }
}
$wantNames = @($Item) + @($Aliases | Where-Object { $_ })
$seen = @{}
foreach ($n in $wantNames) {
  $k = Get-NameKey $n
  if ($seen.ContainsKey($k)) { Die ("'" + $n + "' is offered twice in this one request") }
  $seen[$k] = $true
  if ($claimed.ContainsKey($k)) { Die ("NAME COLLISION: '" + $n + "' is already claimed by row '" + $claimed[$k] + "'. An alias resolves to exactly one row. Rename, or drop the other claim first (-DropAliasFrom).") }
}

# ---- the alias drop, if one was declared -----------------------------------------------------------------
$rowRx = '\{[^{}]*"item":\s*"' + [regex]::Escape($DropAliasFrom) + '",[^{}]*\}'
$dropIdx = -1
if ($DropAliasFrom) {
  $dm = [regex]::Match($raw, $rowRx)
  if (-not $dm.Success) { Die ("no row for -DropAliasFrom '" + $DropAliasFrom + "'") }
  $dropRow = $dm.Value
  if ($dropRow -notmatch ('"' + [regex]::Escape($Item) + '"')) { Die ("row '" + $DropAliasFrom + "' does not claim '" + $Item + "' as an alias - nothing to drop") }
  for ($i = 0; $i -lt $before.Count; $i++) { if ((Get-NameKey $before[$i].item) -eq (Get-NameKey $DropAliasFrom)) { $dropIdx = $i } }
  if ($dropIdx -lt 0) { Die ("could not locate '" + $DropAliasFrom + "' in the parsed rows") }
  # Remove exactly the one alias string, and the comma that joined it to a neighbour if it had one.
  $newDrop = $dropRow
  $aliasRx = '(?<lead>"aliases":\s*\[)(?<body>[^\]]*)(?<tail>\])'
  $am = [regex]::Match($newDrop, $aliasRx)
  if (-not $am.Success) { Die ("row '" + $DropAliasFrom + "' has no aliases array") }
  $kept = @()
  foreach ($q in [regex]::Matches($am.Groups['body'].Value, '"([^"]*)"')) {
    if ((Get-NameKey $q.Groups[1].Value) -ne (Get-NameKey $Item)) { $kept += $q.Groups[1].Value }
  }
  $body = if ($kept.Count -gt 0) { "`r`n" + (($kept | ForEach-Object { '                        "' + $_ + '"' }) -join ",`r`n") + "`r`n                    " } else { '' }
  $newDrop = $newDrop.Substring(0, $am.Index) + $am.Groups['lead'].Value + $body + ']' + $newDrop.Substring($am.Index + $am.Length)
  if ($DropAliasRuling) {
    if ($newDrop -match '"alias_ruling":\s*"') {
      $newDrop = [regex]::Replace($newDrop, '("alias_ruling":\s*")[^"]*(")', ('${1}' + ($DropAliasRuling -replace '\\', '\\' -replace '"', '\"') + '${2}'))
    } else { Die ("row '" + $DropAliasFrom + "' has no alias_ruling to replace") }
  }
  $raw = $raw.Substring(0, $dm.Index) + $newDrop + $raw.Substring($dm.Index + $dm.Length)
  Say ("add-ingredient-row: dropping alias '" + $Item + "' from row '" + $DropAliasFrom + "' (" + $kept.Count + ' alias(es) remain)')
}

# ---- build the new row -----------------------------------------------------------------------------------
$fields = New-Object System.Collections.ArrayList
[void]$fields.Add('"item":  "' + $Item + '"')
[void]$fields.Add('"bid":  "' + $Bid + '"')
[void]$fields.Add('"gpu":  ' + $Gpu)
[void]$fields.Add('"unit":  "' + $Unit + '"')
[void]$fields.Add('"board":  "' + $Board + '"')
if ($BuyPkgG -ge 0)  { [void]$fields.Add('"buy_pkg_g":  ' + $BuyPkgG) }
if ($BuyPkgLabel)    { [void]$fields.Add('"buy_pkg_label":  "' + $BuyPkgLabel + '"') }
if ($PantryPkgG -ge 0)  { [void]$fields.Add('"pantry_pkg_g":  ' + $PantryPkgG) }
if ($PantryPkgLabel)    { [void]$fields.Add('"pantry_pkg_label":  "' + $PantryPkgLabel + '"') }
if ($Bulk)              { [void]$fields.Add('"bulk":  true') }
if ($Note)           { [void]$fields.Add('"note":  "' + ($Note -replace '\\', '\\' -replace '"', '\"') + '"') }
if ($Aliases.Count -gt 0) {
  [void]$fields.Add('"aliases":  [' + "`r`n" + (($Aliases | ForEach-Object { '                        "' + $_ + '"' }) -join ",`r`n") + "`r`n" + '                    ]')
}
if ($AliasRuling)    { [void]$fields.Add('"alias_ruling":  "' + ($AliasRuling -replace '\\', '\\' -replace '"', '\"') + '"') }
$block = "    {`r`n" + (($fields | ForEach-Object { '        ' + $_ }) -join ",`r`n") + "`r`n    }"

# ---- append as TEXT, before the array's closing bracket ---------------------------------------------------
$closeArr = $raw.LastIndexOf(']')
if ($closeArr -lt 0) { Die 'could not find the end of the ingredients array' }
$newRaw = $raw.Substring(0, $closeArr).TrimEnd() + ",`r`n" + $block + "`r`n" + $raw.Substring($closeArr)

# ---- prove it --------------------------------------------------------------------------------------------
$afterParsed = $null
try { $afterParsed = $newRaw | ConvertFrom-Json } catch { Die ('the edit produced invalid JSON, nothing written: ' + $_.Exception.Message) }
$after = @($afterParsed)
if ($after.Count -ne $before.Count + 1) { Die ('row count went ' + $before.Count + ' -> ' + $after.Count + ', expected +1; refusing.') }

# Every pre-existing row byte-identical, except the declared drop row, whose ONLY permitted differences are
# the removed alias and the replaced ruling string. Anything else there is collateral damage too.
$collateral = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $before.Count; $i++) {
  $b = $before[$i]; $a = $after[$i]
  if ($i -eq $dropIdx) {
    $bNames = @(Get-RowNames $b | Where-Object { (Get-NameKey $_) -ne (Get-NameKey $Item) } | ForEach-Object { Get-NameKey $_ })
    $aNames = @(Get-RowNames $a | ForEach-Object { Get-NameKey $_ })
    if (($bNames -join '|') -ne ($aNames -join '|')) { [void]$collateral.Add([string]$b.item + ' (alias list changed beyond the declared drop)'); continue }
    $bo = $b | Select-Object -Property * -ExcludeProperty aliases, alias_ruling | ConvertTo-Json -Depth 10 -Compress
    $ao = $a | Select-Object -Property * -ExcludeProperty aliases, alias_ruling | ConvertTo-Json -Depth 10 -Compress
    if ($bo -ne $ao) { [void]$collateral.Add([string]$b.item + ' (a field other than aliases/alias_ruling changed)') }
    continue
  }
  if (($b | ConvertTo-Json -Depth 10 -Compress) -ne ($a | ConvertTo-Json -Depth 10 -Compress)) { [void]$collateral.Add([string]$b.item) }
}
if ($collateral.Count -gt 0) { Die ('COLLATERAL DAMAGE: ' + $collateral.Count + ' existing row(s) changed (' + ((@($collateral.ToArray()) | Select-Object -First 5) -join '; ') + '). Nothing written.') }

$new = $after[$after.Count - 1]
if ([string]$new.item -ne $Item) { Die 'the appended row is not the row that was offered; refusing.' }

Say ('add-ingredient-row: ' + $before.Count + ' -> ' + $after.Count + ' rows, 0 collateral changes, JSON re-parsed clean')
Say ('    {0,-24} bid {1,-22} {2,8} g per {3}  board={4}' -f $Item, $Bid, $Gpu, $Unit, $Board)
Say ('    feed says {0} is ${1}/{2} at {3}, n={4} store(s)' -f $Bid, $fr.Value.cheapest, $feedUnit, $fr.Value.store, $fr.Value.n)
if ($Aliases.Count -gt 0) { Say ('    aliases: ' + ($Aliases -join ' | ')) }

if (-not $Apply) { Say '    DRY RUN - nothing written. Re-run with -Apply.'; exit 0 }
[IO.File]::WriteAllText($IngredientsFile, $newRaw, (New-Object System.Text.UTF8Encoding($false)))
Say ('    wrote ' + $IngredientsFile)
Say ('    NEXT: specs still carry the OLD bid inline - rebid-ingredient.ps1 -Item ''' + $Item + ''' -ToBid ' + $Bid + ' -ToUnit ' + $Unit + ' -ToGpu ' + $Gpu + ' -FromBid <old bid> -Apply')
exit 0
