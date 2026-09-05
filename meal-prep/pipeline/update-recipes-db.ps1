# update-recipes-db.ps1 (pipeline, run-agnostic - promoted 2026-07-27 from archive\r300; the string-splice
# machinery and the ITEM_ID CONVENTION are UNCHANGED, hardcoded r300 paths became parameters).
# Adds a run's validated recipes (specs) to recipes-db.json.
# Usage: update-recipes-db.ps1 -RunDir <run folder> [-DryRun]
#
# PORT OF r100\update-recipes-db5.ps1 (v5, the one that actually worked). Every PS5.1 JSON SERIALIZER
# failed at this job on a file this size (ConvertTo-Json OOM / ArgumentOutOfRange, JavaScriptSerializer
# InvalidOperation). PARSING works, so each recipe is hand-built as JSON text, parse-validated on its own,
# and spliced into the live file's own known-valid text. recipes-db.json is now ~1.6 MB / 213 recipes and
# this run adds 300 more, so the string-splice path is the only safe one.
#
# R300 deltas vs r100 v5:
#   * splices into the CURRENT recipes-db.json (backed up first) instead of a stale backup copy
#   * writes the two fields normalize-recipe-ids.ps1 stamps site-wide, so the new rows match the
#     existing 213 exactly on day one: per-recipe  protein  and per-ingredient  item_id.
#   * ITEM_ID CONVENTION (auditor B4, 2026-07-25): the id is looked up in ingredient-map.json FIRST -
#     the convention the live 213 already use - and only falls back to the spec's scaler bid for items
#     ingredient-map does not carry. The merged map the CARDS use lets r100-board-map win, which yields
#     a different id for ~40 high-frequency items (chicken-thighs vs boneless-skinless-chicken-thigh,
#     rice vs jasmine-rice, ground-beef-8020 vs 93-7-ground-beef - and the feed prices those two
#     families differently, $5.56 vs $6.17). One physical item must have ONE id in recipes-db or the
#     meal-plan-builder grocery merge and any cross-recipe recosting double-count it. The CARD scaler
#     payloads deliberately keep their current bids (live r100 precedent; the feed carries both
#     families), so this divergence is resolved in the database only.
#     Fallback ids are listed at the end of the run - they are the r300-new commodities that
#     ingredient-map has not adopted yet, not guesses.
#     Because of this, re-running normalize-recipe-ids.ps1 over these rows is now SAFE for every
#     ingredient-map item and would only null the fallback ids.
#   * lookup key is the CANONICAL item name (scaler.canon when a card renames an ingredient for the
#     reader, e.g. the japchae glass noodles), never the display name.
#   * -DryRun prints the delta and writes nothing. -SpecList overrides the slug list; when
#     specs-ready.txt is absent (before the auditor GO) a dry run falls back to specs-full-ok.txt.
param([Parameter(Mandatory=$true)][string]$RunDir,   # the run's working folder
      [string]$SpecsDir,          # default <RunDir>\specs
      [string]$DbPath,            # default <meal-prep>\recipes-db.json
      [string]$IngredientMapFile, # default <meal-prep>\ingredient-map.json (THE live item_id convention)
      [string]$RunLabel,          # provenance tag in each row's notes; default = RunDir leaf name
      [switch]$DryRun,[string]$SpecList,[string[]]$Replace)   # -Replace <slugs>: remove those existing rows first (via Remove-RecipeRow), then re-add fresh from their specs - the single-recipe REPLACE flow. Scopes the run to just those slugs.
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path     # ...\meal-prep\pipeline
$mp = Split-Path -Parent $here
. (Join-Path $mp 'lib\json-db-io.ps1')
Add-Type -AssemblyName System.Web.Extensions
$js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$js.MaxJsonLength = [int]::MaxValue

if(-not (Test-Path $RunDir)){ throw ("RunDir not found: $RunDir") }
if(-not $SpecsDir){          $SpecsDir          = Join-Path $RunDir 'specs' }
if(-not $DbPath){            $DbPath            = Join-Path $mp 'recipes-db.json' }
if(-not $IngredientMapFile){ $IngredientMapFile = Join-Path $mp 'ingredient-map.json' }
if(-not $RunLabel){          $RunLabel          = Split-Path -Leaf (Resolve-Path $RunDir).Path }
$dbPath = $DbPath
# ROW HISTORY THE SPEC DOES NOT OWN. -Replace rebuilds a row from its spec, and two of the row's fields
# are NOT the spec's to state:
#   visibility - owned by rotate-free-dinners. The spec's copy is a FIRST-PUBLISH DEFAULT (SPEC-SCHEMA)
#                and the builder below hardcodes "paid" regardless, so replacing a row that the weekly
#                rotation had set PUBLIC silently paywalled a free dinner. Measured 2026-08-05: 20 rows
#                were public at the time, one of them a slug this very lane was about to repair.
#   published  - the date the recipe went live, a historical fact. Stamping today over it on a content
#                repair makes a two-week-old recipe look new to every surface that sorts by it.
# Captured BEFORE Remove-RecipeRow deletes the row, because after that the old values are gone.
$carryRows = @{}
if($Replace){
  $preDoc = Get-Content $dbPath -Raw -Encoding utf8 | ConvertFrom-Json
  foreach($row in @($preDoc.recipes)){
    if($Replace -notcontains [string]$row.slug){ continue }
    $carryRows[[string]$row.slug] = @{
      visibility = $(if($row.PSObject.Properties.Name -contains 'visibility' -and $row.visibility){ [string]$row.visibility } else { $null })
      published  = $(if($row.PSObject.Properties.Name -contains 'published'  -and $row.published ){ [string]$row.published  } else { $null })
    }
  }
}
if($Replace -and -not $DryRun){
  Copy-Item $dbPath ($dbPath + '.bak-replace') -Force
  foreach($rs in $Replace){
    if([regex]::IsMatch([IO.File]::ReadAllText($dbPath), '"slug"\s*:\s*"' + [regex]::Escape($rs) + '"')){
      [void](Remove-RecipeRow -DbPath $dbPath -Slug $rs); Write-Output ("  -Replace removed existing row: $rs")
    }
  }
}
$raw = [IO.File]::ReadAllText($dbPath)
$iClose = $raw.LastIndexOf(']')
if($raw.Substring($iClose) -notmatch '^\]\s*\}\s*$'){ throw 'unexpected tail - recipes-db.json is not {..., recipes:[...]}' }

$have=@{}
foreach($m in [regex]::Matches($raw, '"slug"\s*:\s*"([^"]+)"')){ $have[$m.Groups[1].Value]=1 }
Write-Output ("live recipes-db slugs: " + $have.Count)

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage

function J([string]$s){
  if($null -eq $s){ return '""' }
  $sb=New-Object Text.StringBuilder
  [void]$sb.Append('"')
  foreach($ch in $s.ToCharArray()){
    switch($ch){
      '"'{[void]$sb.Append('\"')} '\'{[void]$sb.Append('\\')}
      "`n"{[void]$sb.Append('\n')} "`r"{[void]$sb.Append('\r')} "`t"{[void]$sb.Append('\t')}
      default{ if([int]$ch -lt 32){ [void]$sb.AppendFormat('\u{0:x4}',[int]$ch) } else { [void]$sb.Append($ch) } }
    }
  }
  [void]$sb.Append('"')
  $sb.ToString()
}
function N($v){ ([double]$v).ToString([Globalization.CultureInfo]::InvariantCulture) }

# item -> board id, the LIVE convention (ingredient-map.json). Keyed case-insensitively on the item name.
$ingMap=@{}
foreach($e in ((Read-JsonFile $IngredientMapFile).mappings)){
  if($e.board_id){ $ingMap[([string]$e.item).ToLower().Trim()] = [string]$e.board_id }
}
Write-Output ("ingredient-map ids available: " + $ingMap.Count)

$listFile = $SpecList
if(-not $listFile){
  $listFile = Join-Path $RunDir 'specs-ready.txt'
  if(-not (Test-Path $listFile)){
    $alt = Join-Path $RunDir 'specs-full-ok.txt'
    if($DryRun -and (Test-Path $alt)){ Write-Warning 'specs-ready.txt absent (pre auditor GO) - dry run using specs-full-ok.txt'; $listFile = $alt }
  }
}
if(-not (Test-Path $listFile)){ throw ('slug list not found: ' + $listFile) }
Write-Output ("slug list: " + (Split-Path -Leaf $listFile))
$ready = Get-Content $listFile | Where-Object { $_ }
if($Replace){ $ready = @($ready | Where-Object { $Replace -contains $_ }); Write-Output ("  -Replace scoped run to " + $ready.Count + " slug(s)") }
$today = Get-Date -Format 'yyyy-MM-dd'
$parts = New-Object System.Collections.Generic.List[string]
$added=0; $skipped=0; $noId=0; $fromIngMap=0; $fromBid=0; $divergent=@{}; $fallbackItems=@{}
foreach($slug in $ready){
  if($have.ContainsKey($slug)){ $skipped++; continue }
  $s = $js.DeserializeObject([IO.File]::ReadAllText((Join-Path $SpecsDir "$slug.json")))
  $stat=$s['stat']
  $ingParts=@()
  foreach($sc in $s['scaler']['ing']){
    # canonical name is the identity; scaler.item may be a reader-facing rename
    $canon = if($sc.ContainsKey('canon') -and $sc['canon']){ [string]$sc['canon'] } else { [string]$sc['item'] }
    $bid = if($sc.ContainsKey('bid')){ [string]$sc['bid'] } else { '' }
    $key = $canon.ToLower().Trim()
    $id = $null
    if($ingMap.ContainsKey($key)){
      $id = $ingMap[$key]; $fromIngMap++
      if($bid -and $bid -ne $id){ $divergent[($canon + ' :: card bid ' + $bid + ' -> db id ' + $id)] = [int]$divergent[($canon + ' :: card bid ' + $bid + ' -> db id ' + $id)] + 1 }
    } elseif($bid){
      $id = $bid; $fromBid++; $fallbackItems[($canon + ' -> ' + $bid)] = [int]$fallbackItems[($canon + ' -> ' + $bid)] + 1
    } else { $noId++ }
    $idJson = if($id){ (J $id) } else { 'null' }
    $ingParts += ('{"item":' + (J $canon) + ',"grams":' + [int]$sc['grams'] + ',"buy":' + (J $sc['buy']) + ',"item_id":' + $idJson + '}')
  }
  # a replaced row keeps the visibility the rotation gave it and the date it actually went live;
  # a genuinely NEW row is paid and published today, which is what a first publish means
  $carry = $carryRows[$slug]
  $visOut = if($carry -and $carry.visibility){ [string]$carry.visibility } else { 'paid' }
  $pubOut = if($carry -and $carry.published ){ [string]$carry.published  } else { $today }
  $rec = '{' +
    '"name":' + (J $s['name']) + ',"slug":' + (J $slug) + ',"visibility":' + (J $visOut) + ',"cuisine":' + (J $s['cuisine']) + ',"servings":14,' +
    '"ingredients":[' + ($ingParts -join ',') + '],' +
    '"per_serving":{"calories":' + [int]$stat['cal'] + ',"protein_g":' + [int]$stat['protein'] + ',"carbs_g":' + [int]$stat['carbs'] + ',"fat_g":' + [int]$stat['fat'] + '},' +
    '"batch":{"calories":' + ([int]$stat['cal']*14) + ',"protein_g":' + ([int]$stat['protein']*14) + ',"carbs_g":' + ([int]$stat['carbs']*14) + ',"fat_g":' + ([int]$stat['fat']*14) + '},' +
    '"cost_per_serving":' + (N $s['cost_per_serving']) + ',"cost_batch":' + (N $s['cost_batch']) + ',' +
    '"cost_batch_true":' + (N $s['cost_batch_true']) + ',"cost_per_serving_true":' + (N $s['cost_per_serving_true']) + ',' +
    '"cost_pantry_add":' + (N $s['cost_pantry_add']) + ',"cost_first_run":' + (N $s['cost_first_run']) + ',' +
    '"published":' + (J $pubOut) + ',"source_url":' + (J $s['source_url']) + ',"source_site":' + (J $s['source_site']) + ',' +
    '"notes":' + (J ($RunLabel + ' build ' + $today + '; adapted from ' + $s['source_site'] + '; macros computed from food-macros-db')) + ',' +
    '"protein":' + (J ([string]$s['protein'])) +
  '}'
  # parse-validate this part alone (parsing works; serialization was the broken half)
  $null = $js.DeserializeObject($rec)
  $parts.Add($rec)
  $added++
}
Write-Output ("built + parse-validated new recipes: {0} (skipped already-present: {1})" -f $added,$skipped)
Write-Output ("item_id source: ingredient-map {0} rows | scaler-bid fallback {1} rows | no id (null) {2} rows" -f $fromIngMap,$fromBid,$noId)
if($divergent.Count -gt 0){
  Write-Output ("ids re-pointed to the live convention (" + $divergent.Count + " distinct items):")
  $divergent.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { Write-Output ('  ' + $_.Key + '  x' + $_.Value) }
}
if($fallbackItems.Count -gt 0){
  Write-Output ("scaler-bid fallbacks, ingredient-map does not carry these yet (" + $fallbackItems.Count + " distinct items):")
  $fallbackItems.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { Write-Output ('  ' + $_.Key + '  x' + $_.Value) }
}
if($added -eq 0){ Write-Output 'nothing to add'; return }

$out = $raw.Substring(0, $iClose) + ',' + ($parts -join ',') + $raw.Substring($iClose)
$slugCount = [regex]::Matches($out, '"slug"\s*:\s*"([^"]+)"').Count
if($slugCount -ne ($have.Count + $added)){ throw ("slug count {0} != {1}" -f $slugCount, ($have.Count+$added)) }
if($slugCount -lt $have.Count){ throw 'never-shrink violation' }
if($DryRun){ Write-Output ("DRY RUN - would write {0} recipes ({1} + {2} new). Nothing written." -f $slugCount,$have.Count,$added); return }

Copy-Item $dbPath (Join-Path $RunDir ('recipes-db.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json'))
[IO.File]::WriteAllText($dbPath, $out, (New-Object Text.UTF8Encoding($false)))
# final proof: the written file still parses as a whole
$chk = $js.DeserializeObject([IO.File]::ReadAllText($dbPath))
Write-Output ("recipes-db WRITTEN + reparsed: {0} total recipes ({1} + {2} new)" -f $chk['recipes'].Count, $have.Count, $added)
