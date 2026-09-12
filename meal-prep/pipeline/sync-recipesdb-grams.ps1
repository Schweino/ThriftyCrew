<#
  sync-recipesdb-grams.ps1 - carry an ingredient WEIGHT repair from the specs into recipes-db.json.

  WHY THIS EXISTS (2026-09-12). db\recipes\<slug>.json is where a recipe's grams are AUTHORED, but
  recipes-db.json keeps its own copy of every ingredient's grams, and gen-planner-data.ps1 builds the Meal
  Plan Builder from THAT copy. sync-recipesdb-buy, -cost and -macros carry the labels, the cost block and
  the per-serving macros across. NOTHING carried grams, and engine\audit-db-agreement.ps1 never compared
  them, so a weight repair that stopped at the specs reached no reader of the planner and nothing said so.

  Two rulings were stranded that way, both on 2026-09-02 and both in 59831927d / a7a86667b:
    * Canned corn and canned pineapple were ruled DRAINED, and 19 spec lines were re-grammed x 298/432 and
      x 412/567. The index kept the GROSS grams. The planner's package basis had moved to drained
      (gen-planner-data corn04), so it divided gross grams by a drained can and told shoppers to buy extra
      cans: arroz-con-carne-molida read 1,008 g against 298 g cans, 4 cans where the recipe needs 3.
    * honey-bbq-chicken-mac-and-cheese's pasta-water salt came off the ingredient line (23 of the 24 specs
      that salt pasta water book it as a cook's note, and this one billed the drain at full weight), so the
      spec's label went from 10 1/2 to 7 teaspoons and its grams from 63 to 42, together. The index kept both.
  engine\audit-published-macros.ps1 found all 20 on the day it shipped; this is the repair it had nowhere to send.

  IT CARRIES ONLY NAMED, PROVEN CLASSES ACROSS, the rule sync-recipesdb-buy.ps1 states and this copies.
  "The spec is the source of truth" says where a value is AUTHORED; it is not a licence to overwrite the
  index with whatever a spec holds today. Every other disagreement is REPORTED, never rewritten.

    drained-regram   The spec was re-grammed by a drained-basis ruling, and the arithmetic proves it: the
                     item's db\densities.json `can` sits at least 5% under its db\ingredients.json buy_pkg_g
                     (the same test cost-recipes.ps1 uses to take the drained branch), and
                     round(index grams x can / buy_pkg_g) equals the spec grams to the gram. A spec that is
                     merely close is a hand edit and is refused. If the two buy labels differ, the class
                     carries the label too only when the index label is a bare ounce weight and the spec's is
                     exactly round(ounces x the same factor) + " oz, drained" - which is what the ruling wrote.
                     Measured on the tree it shipped against: 19 of 19 grams and 5 of 5 labels reproduced.

    reviewed         No arithmetic derives it - a line removed from a compound label is not a ratio - so a
                     person decided it and recorded the decision in out\grams-carry.json, with a reason. The
                     index's current grams and the spec's must both match the manifest EXACTLY: the old value
                     proves the index has not moved since the review, the new value proves the spec still holds
                     what was reviewed. When the two labels differ, the manifest must name both labels exactly
                     too, and the label travels WITH the grams: carrying the weight alone would leave the index
                     stating "10 1/2 teaspoons" beside 42 g, which is worse than the stale copy it replaced.
                     An entry with no reason is refused. Absent manifest, this class carries NOTHING.

  A SPEC THAT DISAGREES WITH ITSELF IS NEVER A SOURCE. If a line's ingredients_grams and its scaler grams
  differ, the row is refused whatever class it would have been - there is no single authored value to carry.

  A RUN THAT COULD NOT LOAD ITS EVIDENCE SAYS SO. If the density or package tables load EMPTY the drained
  class cannot fire, and every row would read "a person decides it" - output that looks like a finding and is
  a broken loader. The first version of this file did exactly that: wrapping the json-io reader's return in @() reads
  the returned array as ONE element (ps-json-array-collapse), the package table held 0 of 226 rows, and a dry
  run reported all 20 as undecided while its self-test passed, because the self-test handed the tables in
  directly and never read a file. So an empty table is exit 3 and writes nothing, and the self-test now runs
  this script against real files on disk.

  AFTER -Apply, in this order: meal-prep\gen-planner-data.ps1 (the planner reads the index, so nothing reaches
  a reader until this runs and its output is committed), then engine\audit-published-macros.ps1, whose
  index_grams_vs_spec list falls and needs -Tighten or -Accept to record it.

  Read-only unless -Apply. Exit 0, or 3 when the evidence tables could not be loaded.
  Usage: .\sync-recipesdb-grams.ps1 [-Apply]   |   .\sync-recipesdb-grams.ps1 -SelfTest
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = '')
$ErrorActionPreference = 'Stop'
$__jioRoot = $PSScriptRoot; while ($__jioRoot -and -not (Test-Path (Join-Path $__jioRoot 'lib\json-io.ps1'))) { $__jioRoot = Split-Path $__jioRoot -Parent }
if (-not $__jioRoot) { throw 'json-io.ps1 not found walking up from ' + $PSScriptRoot }
. (Join-Path $__jioRoot 'lib\json-io.ps1')
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path (Split-Path -Parent $here) 'lib\json-db-io.ps1')

# cost-recipes.ps1 takes the drained branch when densities.can sits at least 5% under buy_pkg_g. The same
# test here, so this tool can never call a basis drained that the engine does not price as drained.
$script:DRAINED_MARGIN = 0.95

function Get-SpecGramMap([string]$specDir) {
  <# slug -> @{ canonical item = <Grams, Buy, Item, IgGrams> } off the specs. canon is the join key recipes-db
     uses. IgGrams is the same line's ingredients_grams value, or $null when that list does not name it. #>
  $map = @{}
  foreach ($f in @(Get-ChildItem (Join-Path $specDir '*.json') | Where-Object { $_.Name -ne '_index.json' })) {
    $spec = $null
    try { $spec = (Read-SpecText $f.FullName).Text | ConvertFrom-Json } catch { continue }
    if (-not $spec.scaler -or -not $spec.scaler.ing) { continue }
    $ig = @{}
    if ($spec.PSObject.Properties.Name -contains 'ingredients_grams') {
      foreach ($r in @($spec.ingredients_grams)) { if ($r -and $r.item) { $ig[[string]$r.item] = [double]$r.grams } }
    }
    $m = @{}
    foreach ($i in @($spec.scaler.ing)) {
      $canon = if ($i.PSObject.Properties.Name -contains 'canon' -and $i.canon) { [string]$i.canon } else { [string]$i.item }
      $g = if ($i.PSObject.Properties.Name -contains 'grams' -and $null -ne $i.grams) { [double]$i.grams } else { -1 }
      $igv = $null
      if ($ig.ContainsKey($canon)) { $igv = $ig[$canon] } elseif ($ig.ContainsKey([string]$i.item)) { $igv = $ig[[string]$i.item] }
      $m[$canon] = [pscustomobject]@{ Grams = $g; Buy = [string]$i.buy; Item = [string]$i.item; IgGrams = $igv }
    }
    $map[$f.BaseName] = $m
  }
  return $map
}

function Get-GramEvidence([string]$root) {
  <# The two evidence tables off disk. ASSIGN, THEN WRAP: `@(Read-JsonFile x)` reads a returned array as ONE
     element, which is how this loader first returned 0 package weights out of 226. #>
  $canG = @{}
  $densDoc = Read-JsonFile (Join-Path $root 'db\densities.json')
  if ($densDoc -and $densDoc.PSObject.Properties['items'] -and $densDoc.items) {
    foreach ($p in $densDoc.items.PSObject.Properties) { if ($p.Value -and $p.Value.PSObject.Properties['can'] -and $p.Value.can) { $canG[$p.Name] = [double]$p.Value.can } }
  }
  $pkgG = @{}
  $ingRows = Read-JsonFile (Join-Path $root 'db\ingredients.json')
  foreach ($row in @($ingRows)) {
    if ($row -and $row.PSObject.Properties['buy_pkg_g'] -and $row.buy_pkg_g) { $pkgG[[string]$row.item] = [double]$row.buy_pkg_g }
  }
  $manifest = $null
  $manPath = Join-Path $root 'out\grams-carry.json'
  if (Test-Path -LiteralPath $manPath) {
    $manifest = @{}
    $manRows = Read-JsonFile $manPath
    foreach ($e in @($manRows)) {
      if (-not $e -or -not $e.slug) { continue }
      $ob = if ($e.PSObject.Properties['old_buy']) { [string]$e.old_buy } else { $null }
      $nb = if ($e.PSObject.Properties['new_buy']) { [string]$e.new_buy } else { $null }
      $manifest[([string]$e.slug + '|' + [string]$e.item)] = [pscustomobject]@{ Old = [double]$e.old_grams; New = [double]$e.new_grams; OldBuy = $ob; NewBuy = $nb; Reason = [string]$e.reason }
    }
  }
  return [pscustomobject]@{ CanG = $canG; PkgG = $pkgG; Manifest = $manifest }
}

function Get-GramCarryClass {
  <# Name the carry class for one disagreeing weight, or return Class '' with the reason it does not qualify.
     Pure, so every refusal is a case the self-test can pin. #>
  param(
    [Parameter(Mandatory)][string]$Slug,
    [Parameter(Mandatory)][string]$Item,
    [double]$IdxGrams,
    [double]$SpecGrams,
    $IgGrams = $null,
    [AllowEmptyString()][string]$IdxBuy = '',
    [AllowEmptyString()][string]$SpecBuy = '',
    [double]$CanG = 0,
    [double]$PkgG = 0,
    $Manifest = $null
  )
  if ($SpecGrams -le 0) { return [pscustomobject]@{ Class = ''; NewBuy = $null; Reason = 'the spec states no grams' } }
  if ($null -ne $IgGrams -and [math]::Abs([double]$IgGrams - $SpecGrams) -gt 0.5) {
    return [pscustomobject]@{ Class = ''; NewBuy = $null; Reason = ("the spec disagrees with itself (ingredients_grams {0} vs scaler {1}) - there is no single value to carry" -f $IgGrams, $SpecGrams) }
  }
  $labelsDiffer = -not [string]::Equals($IdxBuy, $SpecBuy, [StringComparison]::Ordinal)
  if ($CanG -gt 0 -and $PkgG -gt 0 -and $CanG -le ($PkgG * $script:DRAINED_MARGIN)) {
    $f = $CanG / $PkgG
    if ([math]::Round($IdxGrams * $f) -eq [math]::Round($SpecGrams)) {
      if (-not $labelsDiffer) { return [pscustomobject]@{ Class = 'drained-regram'; NewBuy = $null; Reason = '' } }
      $m = [regex]::Match($IdxBuy, '^\s*([0-9]+(?:\.[0-9]+)?)\s*oz\s*$')
      if ($m.Success) {
        $want = ('{0} oz, drained' -f [math]::Round([double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) * $f))
        if ([string]::Equals($want, $SpecBuy, [StringComparison]::Ordinal)) {
          return [pscustomobject]@{ Class = 'drained-regram'; NewBuy = $SpecBuy; Reason = '' }
        }
      }
      return [pscustomobject]@{ Class = ''; NewBuy = $null; Reason = ("grams reproduce the drained ruling but the labels differ in a way it cannot derive (db '{0}' vs spec '{1}')" -f $IdxBuy, $SpecBuy) }
    }
  }
  if ($Manifest) {
    $k = $Slug + '|' + $Item
    if ($Manifest.ContainsKey($k)) {
      $e = $Manifest[$k]
      if (-not $e.Reason) { return [pscustomobject]@{ Class = ''; NewBuy = $null; Reason = 'a reviewed manifest entry with no reason is not a review' } }
      if ([math]::Abs([double]$e.Old - $IdxGrams) -gt 0.5) {
        return [pscustomobject]@{ Class = ''; NewBuy = $null; Reason = ("the index has moved since the review (manifest expected {0} g)" -f $e.Old) }
      }
      if ([math]::Abs([double]$e.New - $SpecGrams) -gt 0.5) {
        return [pscustomobject]@{ Class = ''; NewBuy = $null; Reason = ("the spec is not what was reviewed (that was {0} g) - looks hand-edited since" -f $e.New) }
      }
      if (-not $labelsDiffer) { return [pscustomobject]@{ Class = 'reviewed'; NewBuy = $null; Reason = '' } }
      if (-not $e.OldBuy -and -not $e.NewBuy) {
        return [pscustomobject]@{ Class = ''; NewBuy = $null; Reason = 'the labels differ and the review names neither - carrying the grams alone would leave the index label contradicting its own weight' }
      }
      if (-not [string]::Equals([string]$e.OldBuy, $IdxBuy, [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ Class = ''; NewBuy = $null; Reason = 'the index label has moved since the review' }
      }
      if (-not [string]::Equals([string]$e.NewBuy, $SpecBuy, [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ Class = ''; NewBuy = $null; Reason = 'the spec label is not what was reviewed - looks hand-edited since' }
      }
      return [pscustomobject]@{ Class = 'reviewed'; NewBuy = $SpecBuy; Reason = '' }
    }
  }
  return [pscustomobject]@{ Class = ''; NewBuy = $null; Reason = 'no carry class proves this - a person decides it, and records the decision in out\grams-carry.json' }
}

function Format-JsonNumber([double]$v) {
  if ($v -eq [math]::Floor($v)) { return ([long]$v).ToString([Globalization.CultureInfo]::InvariantCulture) }
  return $v.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
}

function Sync-RecipesDbGrams {
  <# Pure text in, text out, so the self-test drives the same splice path the live run does. #>
  param(
    [Parameter(Mandatory)][string]$Raw,
    [Parameter(Mandatory)][hashtable]$SpecGrams,
    [hashtable]$CanG = @{},
    [hashtable]$PkgG = @{},
    $Manifest = $null
  )
  $db = $Raw | ConvertFrom-Json
  $changes = New-Object System.Collections.Generic.List[object]
  $drift = New-Object System.Collections.Generic.List[string]
  foreach ($r in @($db.recipes)) {
    $slug = [string]$r.slug
    if (-not $SpecGrams.ContainsKey($slug)) { continue }
    $want = $SpecGrams[$slug]
    foreach ($ing in @($r.ingredients)) {
      $item = [string]$ing.item
      if (-not $want.ContainsKey($item)) { continue }   # a name on one side only is audit-db-agreement's finding
      $w = $want[$item]
      if ($null -eq $ing.grams) { continue }
      $have = [double]$ing.grams
      if ([math]::Abs($have - [double]$w.Grams) -le 0.5) { continue }
      $can = if ($CanG.ContainsKey($item)) { [double]$CanG[$item] } else { 0 }
      $pkg = if ($PkgG.ContainsKey($item)) { [double]$PkgG[$item] } else { 0 }
      $cls = Get-GramCarryClass -Slug $slug -Item $item -IdxGrams $have -SpecGrams ([double]$w.Grams) -IgGrams $w.IgGrams -IdxBuy ([string]$ing.buy) -SpecBuy ([string]$w.Buy) -CanG $can -PkgG $pkg -Manifest $Manifest
      if (-not $cls.Class) { $drift.Add(("{0} :: {1} : db {2} g vs spec {3} g ({4})" -f $slug, $item, $have, $w.Grams, $cls.Reason)); continue }
      $changes.Add([pscustomobject]@{ Slug = $slug; Item = $item; OldG = $have; NewG = [double]$w.Grams; OldBuy = [string]$ing.buy; NewBuy = $cls.NewBuy; Class = $cls.Class })
    }
  }
  if ($changes.Count -eq 0) { return @{ changed = 0; text = $Raw; drift = @($drift.ToArray()); changes = @() } }

  $text = $Raw
  foreach ($g in ($changes | Group-Object Slug)) {
    $slug = $g.Name
    $anchor = '"' + $slug + '"'
    $si = $text.IndexOf($anchor)
    if ($si -lt 0) { throw "grams sync: slug not found: $slug" }
    if ($text.IndexOf($anchor, $si + 1) -ge 0) { throw "grams sync: slug not unique: $slug" }
    $depth = 0; $rowStart = -1
    for ($i = $si; $i -ge 0; $i--) { $c = $text[$i]; if ($c -eq '}') { $depth++ } elseif ($c -eq '{') { if ($depth -eq 0) { $rowStart = $i; break } else { $depth-- } } }
    $depth = 0; $rowEnd = -1
    for ($i = $si; $i -lt $text.Length; $i++) { $c = $text[$i]; if ($c -eq '{') { $depth++ } elseif ($c -eq '}') { if ($depth -eq 0) { $rowEnd = $i; break } else { $depth-- } } }
    if ($rowStart -lt 0 -or $rowEnd -lt 0) { throw "grams sync: brace match failed for $slug" }
    $row = $text.Substring($rowStart, $rowEnd - $rowStart + 1)
    if (($row -split '"slug"').Count -ne 2) { throw "grams sync: row spans !=1 slug for $slug (abort)" }
    $ingAt = Find-JsonValueStart -Raw $row -Key 'ingredients'
    if ($ingAt -lt 0) { throw "grams sync: no ingredients array in $slug" }
    $spans = @(Get-JsonArraySpans -Raw $row -OpenIndex $ingAt)
    $todo = New-Object System.Collections.Generic.List[object]
    foreach ($ch in $g.Group) {
      $hits = @()
      for ($k = 0; $k -lt $spans.Count; $k++) {
        $o = $row.Substring($spans[$k].Start, $spans[$k].End - $spans[$k].Start + 1) | ConvertFrom-Json
        if ([string]$o.item -eq $ch.Item -and $null -ne $o.grams -and [math]::Abs([double]$o.grams - $ch.OldG) -le 0.5) { $hits += $k }
      }
      if ($hits.Count -ne 1) { throw ("grams sync: $slug :: $($ch.Item) matched $($hits.Count) ingredient objects (expected 1)") }
      $todo.Add([pscustomobject]@{ K = $hits[0]; Ch = $ch })
    }
    foreach ($t in @($todo | Sort-Object K -Descending)) {
      $sp = $spans[$t.K]
      $el = $row.Substring($sp.Start, $sp.End - $sp.Start + 1)
      $edits = New-Object System.Collections.Generic.List[object]
      $gAt = Find-JsonValueStart -Raw $el -Key 'grams'
      if ($gAt -lt 0) { throw "grams sync: no grams key in $slug :: $($t.Ch.Item)" }
      $ns = Get-JsonNumberSpan -Raw $el -Start $gAt
      $edits.Add([pscustomobject]@{ Start = $ns.Start; End = $ns.End; Value = (Format-JsonNumber $t.Ch.NewG) })
      if ($null -ne $t.Ch.NewBuy) {
        $bAt = Find-JsonValueStart -Raw $el -Key 'buy'
        if ($bAt -lt 0) { throw "grams sync: no buy key in $slug :: $($t.Ch.Item)" }
        $vs = Get-JsonStringSpan -Raw $el -OpenIndex $bAt
        $cur = $el.Substring($vs.Start, $vs.End - $vs.Start + 1)
        if ($cur -ne $t.Ch.OldBuy) { throw ("grams sync: $slug :: $($t.Ch.Item) buy is '$cur', expected '$($t.Ch.OldBuy)'") }
        $edits.Add([pscustomobject]@{ Start = $vs.Start; End = $vs.End; Value = ([string]$t.Ch.NewBuy).Replace('\', '\\').Replace('"', '\"') })
      }
      # later field first, so the earlier field's offsets still hold
      foreach ($ed in @($edits | Sort-Object Start -Descending)) { $el = $el.Substring(0, $ed.Start) + $ed.Value + $el.Substring($ed.End + 1) }
      $row = $row.Substring(0, $sp.Start) + $el + $row.Substring($sp.End + 1)
    }
    $text = $text.Substring(0, $rowStart) + $row + $text.Substring($rowEnd + 1)
  }
  return @{ changed = $changes.Count; text = $text; drift = @($drift.ToArray()); changes = @($changes.ToArray()) }
}

if ($SelfTest) {
  $fail = 0; $ran = 0
  function Chk([string]$label, [bool]$cond, [string]$got) {
    $script:ran++
    if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
  }
  function Ing2($raw, [string]$slug, [string]$item) {
    $o = $raw | ConvertFrom-Json
    return @(@($o.recipes | Where-Object { $_.slug -eq $slug }).ingredients | Where-Object { $_.item -eq $item })[0]
  }
  $oldSalt = '3 1/2 teaspoons for the chicken; 3 1/2 teaspoons for the cheese sauce; 3 1/2 teaspoons for the pasta water (10 1/2 teaspoons total)'
  $newSalt = '3 1/2 teaspoons for the chicken; 3 1/2 teaspoons for the cheese sauce (7 teaspoons total)'
  # FROZEN FIXTURE - real rows off the tree on 2026-09-12. 'arroz' and 'soup' are compact like the r300 rows;
  # 'pretty' is pretty-printed with two spaces after each colon like the older rows, because a sync that only
  # patches one shape reports success and changes not one byte on the other. 'twin' uses the SAME item at the
  # SAME grams as 'arroz', so a splice that is not row-scoped patches the wrong recipe or refuses. The salt row
  # carries its REAL two labels: the first draft of this fixture gave both sides the same label, which is the
  # wrong premise the first draft of this tool's header was written on.
  $fx = @'
{"recipes":[
{"slug":"arroz","name":"Arroz","ingredients":[{"item":"Sweet Whole Kernel Corn","grams":1008,"buy":"2.3 cans","item_id":"canned-corn"},{"item":"Rice","grams":648,"buy":"3.5 cups dry","item_id":"rice"}]},
{"slug":"twin","name":"Twin","ingredients":[{"item":"Sweet Whole Kernel Corn","grams":1008,"buy":"2.3 cans","item_id":"canned-corn"}]},
{"slug":"soup","name":"Soup","ingredients":[{"item":"Sweet Whole Kernel Corn","grams":289,"buy":"10.25 oz","item_id":"canned-corn"},{"item":"Salt","grams":63,"buy":"3 1/2 teaspoons for the chicken; 3 1/2 teaspoons for the cheese sauce; 3 1/2 teaspoons for the pasta water (10 1/2 teaspoons total)","item_id":"salt"}]},
{"slug":"close","name":"Close","ingredients":[{"item":"Sweet Whole Kernel Corn","grams":1008,"buy":"2.3 cans","item_id":"canned-corn"}]},
{"slug":"torn","name":"Torn","ingredients":[{"item":"Sweet Whole Kernel Corn","grams":1008,"buy":"2.3 cans","item_id":"canned-corn"}]},
{
    "slug":  "pretty",
    "name":  "Pretty",
    "ingredients":  [
                        {
                            "item":  "Pineapple Chunks",
                            "grams":  1155,
                            "buy":  "2 cans",
                            "item_id":  "canned-pineapple"
                        }
                    ]
}
]}
'@
  $spec = @{
    'arroz'  = @{ 'Sweet Whole Kernel Corn' = [pscustomobject]@{ Grams = 695; Buy = '2.3 cans'; Item = 'Sweet Whole Kernel Corn'; IgGrams = 695 }
                  'Rice' = [pscustomobject]@{ Grams = 648; Buy = '3.5 cups dry'; Item = 'Rice'; IgGrams = 648 } }
    'twin'   = @{ 'Sweet Whole Kernel Corn' = [pscustomobject]@{ Grams = 1008; Buy = '2.3 cans'; Item = 'Sweet Whole Kernel Corn'; IgGrams = 1008 } }
    'soup'   = @{ 'Sweet Whole Kernel Corn' = [pscustomobject]@{ Grams = 199; Buy = '7 oz, drained'; Item = 'Sweet Whole Kernel Corn'; IgGrams = 199 }
                  'Salt' = [pscustomobject]@{ Grams = 42; Buy = $newSalt; Item = 'Salt'; IgGrams = 42 } }
    'close'  = @{ 'Sweet Whole Kernel Corn' = [pscustomobject]@{ Grams = 700; Buy = '2.3 cans'; Item = 'Sweet Whole Kernel Corn'; IgGrams = 700 } }
    'torn'   = @{ 'Sweet Whole Kernel Corn' = [pscustomobject]@{ Grams = 695; Buy = '2.3 cans'; Item = 'Sweet Whole Kernel Corn'; IgGrams = 700 } }
    'pretty' = @{ 'Pineapple Chunks' = [pscustomobject]@{ Grams = 839; Buy = '2 cans'; Item = 'Pineapple Chunks'; IgGrams = 839 } }
  }
  $can = @{ 'Sweet Whole Kernel Corn' = 298; 'Pineapple Chunks' = 412 }
  $pkg = @{ 'Sweet Whole Kernel Corn' = 432; 'Pineapple Chunks' = 567 }

  $r = Sync-RecipesDbGrams -Raw $fx -SpecGrams $spec -CanG $can -PkgG $pkg
  Chk 'MUST FIRE  a drained re-gram the ruling reproduces is carried (1008 -> 695)' ([double](Ing2 $r.text 'arroz' 'Sweet Whole Kernel Corn').grams -eq 695) ([string](Ing2 $r.text 'arroz' 'Sweet Whole Kernel Corn').grams)
  Chk 'MUST FIRE  an ounce label is carried WITH its grams (10.25 oz -> 7 oz, drained)' (([double](Ing2 $r.text 'soup' 'Sweet Whole Kernel Corn').grams -eq 199) -and ([string](Ing2 $r.text 'soup' 'Sweet Whole Kernel Corn').buy -eq '7 oz, drained')) ([string](Ing2 $r.text 'soup' 'Sweet Whole Kernel Corn').buy)
  Chk 'MUST FIRE  a PRETTY-PRINTED row is patched too (1155 -> 839)' ([double](Ing2 $r.text 'pretty' 'Pineapple Chunks').grams -eq 839) ([string](Ing2 $r.text 'pretty' 'Pineapple Chunks').grams)
  Chk 'CLEAN TWIN a row whose grams already agree keeps its value (twin stays 1008, rice stays 648)' (([double](Ing2 $r.text 'twin' 'Sweet Whole Kernel Corn').grams -eq 1008) -and ([double](Ing2 $r.text 'arroz' 'Rice').grams -eq 648)) 'moved'
  Chk 'MUST NOT FIRE a spec merely CLOSE to the ruling (700, ruling says 695) is refused as a hand edit, and reported' (([double](Ing2 $r.text 'close' 'Sweet Whole Kernel Corn').grams -eq 1008) -and (($r.drift -join '|') -match 'close :: Sweet Whole Kernel Corn.*no carry class proves')) ($r.drift -join '|')
  Chk 'MUST NOT FIRE a spec that disagrees with itself (ingredients_grams 700 vs scaler 695) is never a source' (([double](Ing2 $r.text 'torn' 'Sweet Whole Kernel Corn').grams -eq 1008) -and (($r.drift -join '|') -match 'torn :: .*disagrees with itself')) ($r.drift -join '|')
  Chk 'MUST NOT FIRE with no manifest the salt row carries nothing, and says a person decides it' (([double](Ing2 $r.text 'soup' 'Salt').grams -eq 63) -and (($r.drift -join '|') -match 'soup :: Salt.*grams-carry')) ($r.drift -join '|')
  Chk 'the file still parses and keeps all six rows' (@(($r.text | ConvertFrom-Json).recipes).Count -eq 6) 'rows lost'
  Chk 'exactly three changes, each named drained-regram' (($r.changed -eq 3) -and (@($r.changes | Where-Object { $_.Class -eq 'drained-regram' }).Count -eq 3)) ("changed=" + $r.changed)
  $r2 = Sync-RecipesDbGrams -Raw $r.text -SpecGrams $spec -CanG $can -PkgG $pkg
  Chk 'idempotent - a second pass changes nothing' ($r2.changed -eq 0) ("changed=" + $r2.changed)
  # THE FOUNDING TRAP OF THE RULING. Before 2026-09-02 corn's densities.can COPIED the net weight (432 against
  # 432), which is why the drained branch skipped it in silence. With can == buy_pkg_g there is no drained basis.
  $rTrap = Sync-RecipesDbGrams -Raw $fx -SpecGrams $spec -CanG @{ 'Sweet Whole Kernel Corn' = 432; 'Pineapple Chunks' = 412 } -PkgG $pkg
  Chk 'MUST NOT FIRE a can that COPIES the net weight is not a drained basis (the pre-ruling corn state)' ([double](Ing2 $rTrap.text 'arroz' 'Sweet Whole Kernel Corn').grams -eq 1008) ([string](Ing2 $rTrap.text 'arroz' 'Sweet Whole Kernel Corn').grams)
  $cl = Get-GramCarryClass -Slug 'soup' -Item 'Sweet Whole Kernel Corn' -IdxGrams 289 -SpecGrams 199 -IgGrams 199 -IdxBuy '10.25 oz' -SpecBuy '1 cup drained' -CanG 298 -PkgG 432
  Chk 'MUST NOT FIRE grams that reproduce but a label the ruling did not write are refused whole' ($cl.Class -eq '' -and $cl.Reason -match 'labels differ') ("{0} :: {1}" -f $cl.Class, $cl.Reason)

  # THE REVIEWED CLASS. The manifest is the whole trigger; grams AND labels must match it, and travel together.
  $man = @{ 'soup|Salt' = [pscustomobject]@{ Old = 63; New = 42; OldBuy = $oldSalt; NewBuy = $newSalt; Reason = 'pasta-water salt ruling, 59831927d' } }
  $r3 = Sync-RecipesDbGrams -Raw $fx -SpecGrams $spec -CanG $can -PkgG $pkg -Manifest $man
  $salt3 = Ing2 $r3.text 'soup' 'Salt'
  Chk 'MUST FIRE  a reviewed entry carries the weight AND its label together (63 g, 10 1/2 tsp -> 42 g, 7 tsp)' (([double]$salt3.grams -eq 42) -and ([string]$salt3.buy -eq $newSalt) -and (@($r3.changes | Where-Object { $_.Class -eq 'reviewed' }).Count -eq 1)) ("{0} :: {1}" -f $salt3.grams, $salt3.buy)
  $gramsOnly = @{ 'soup|Salt' = [pscustomobject]@{ Old = 63; New = 42; OldBuy = $null; NewBuy = $null; Reason = 'x' } }
  $c7 = Get-GramCarryClass -Slug 'soup' -Item 'Salt' -IdxGrams 63 -SpecGrams 42 -IgGrams 42 -IdxBuy $oldSalt -SpecBuy $newSalt -Manifest $gramsOnly
  Chk 'MUST NOT FIRE a review that names no labels while the labels differ is refused - it would leave the label contradicting the weight' ($c7.Class -eq '' -and $c7.Reason -match 'names neither') $c7.Reason
  $stale = @{ 'soup|Salt' = [pscustomobject]@{ Old = 60; New = 42; OldBuy = $oldSalt; NewBuy = $newSalt; Reason = 'x' } }
  $c4 = Get-GramCarryClass -Slug 'soup' -Item 'Salt' -IdxGrams 63 -SpecGrams 42 -IgGrams 42 -IdxBuy $oldSalt -SpecBuy $newSalt -Manifest $stale
  Chk 'MUST NOT FIRE a manifest whose old grams no longer match the index is refused' ($c4.Class -eq '' -and $c4.Reason -match 'moved since the review') $c4.Reason
  $noReason = @{ 'soup|Salt' = [pscustomobject]@{ Old = 63; New = 42; OldBuy = $oldSalt; NewBuy = $newSalt; Reason = '' } }
  $c5 = Get-GramCarryClass -Slug 'soup' -Item 'Salt' -IdxGrams 63 -SpecGrams 42 -IgGrams 42 -IdxBuy $oldSalt -SpecBuy $newSalt -Manifest $noReason
  Chk 'MUST NOT FIRE a manifest entry with no reason is not a review' ($c5.Class -eq '' -and $c5.Reason -match 'no reason') $c5.Reason
  $edited = @{ 'soup|Salt' = [pscustomobject]@{ Old = 63; New = 42; OldBuy = $oldSalt; NewBuy = '7 teaspoons'; Reason = 'x' } }
  $c6 = Get-GramCarryClass -Slug 'soup' -Item 'Salt' -IdxGrams 63 -SpecGrams 42 -IgGrams 42 -IdxBuy $oldSalt -SpecBuy $newSalt -Manifest $edited
  Chk 'MUST NOT FIRE a spec label that moved after the review reads as a later hand edit' ($c6.Class -eq '' -and $c6.Reason -match 'label is not what was reviewed') $c6.Reason

  # THE LIVE PATH, DRIVEN AGAINST FILES ON DISK. Every case above hands the tables in directly, which is exactly
  # why they passed while the loader returned 0 of 226 package weights. These run THIS script as a child against a
  # temp meal-prep tree whose ingredients.json is a multi-row top-level ARRAY and whose manifest holds TWO entries -
  # the two shapes `@(Read-JsonFile x)` collapses. One directory per run, removed in finally.
  $wt = Join-Path $env:TEMP ('rgx-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $wt -ErrorAction Stop | Out-Null
  try {
    $utf8 = New-Object Text.UTF8Encoding($false)
    function New-RgTree([string]$dir, [bool]$withPkg) {
      New-Item -ItemType Directory -Path (Join-Path $dir 'db\recipes') -Force -ErrorAction Stop | Out-Null
      New-Item -ItemType Directory -Path (Join-Path $dir 'out') -Force -ErrorAction Stop | Out-Null
      [IO.File]::WriteAllText((Join-Path $dir 'db\densities.json'), '{"items":{"Sweet Whole Kernel Corn":{"can":298,"cup":165},"Salt":{"tsp":6}}}', $utf8)
      $ingJson = if ($withPkg) { '[{"item":"Sweet Whole Kernel Corn","buy_pkg_g":432,"buy_pkg_label":"can"},{"item":"Salt","unit":"oz"},{"item":"Rice","buy_pkg_g":907}]' }
                 else          { '[{"item":"Sweet Whole Kernel Corn","buy_pkg_label":"can"},{"item":"Salt","unit":"oz"},{"item":"Rice"}]' }
      [IO.File]::WriteAllText((Join-Path $dir 'db\ingredients.json'), $ingJson, $utf8)
      $sA = [ordered]@{ slug = 'arroz'; ingredients_grams = @([ordered]@{ item = 'Sweet Whole Kernel Corn'; grams = 695 }); scaler = [ordered]@{ ing = @([ordered]@{ item = 'Sweet Whole Kernel Corn'; grams = 695; buy = '2.3 cans' }) } }
      $sB = [ordered]@{ slug = 'salty'; ingredients_grams = @([ordered]@{ item = 'Salt'; grams = 42 }); scaler = [ordered]@{ ing = @([ordered]@{ item = 'Salt'; canon = 'Salt'; grams = 42; buy = $newSalt }) } }
      [IO.File]::WriteAllText((Join-Path $dir 'db\recipes\arroz.json'), ($sA | ConvertTo-Json -Depth 6), $utf8)
      [IO.File]::WriteAllText((Join-Path $dir 'db\recipes\salty.json'), ($sB | ConvertTo-Json -Depth 6), $utf8)
      $idx = '{"recipes":[{"slug":"arroz","name":"A","ingredients":[{"item":"Sweet Whole Kernel Corn","grams":1008,"buy":"2.3 cans"}]},{"slug":"salty","name":"S","ingredients":[{"item":"Salt","grams":63,"buy":"' + $oldSalt + '"}]}]}'
      [IO.File]::WriteAllText((Join-Path $dir 'recipes-db.json'), $idx, $utf8)
      $manJson = '[{"slug":"salty","item":"Salt","old_grams":63,"new_grams":42,"old_buy":"' + $oldSalt + '","new_buy":"' + $newSalt + '","reason":"fixture: pasta-water salt ruling"},{"slug":"decoy","item":"Salt","old_grams":1,"new_grams":2,"old_buy":"a","new_buy":"b","reason":"a second entry, because one entry is the shape that does not collapse"}]'
      [IO.File]::WriteAllText((Join-Path $dir 'out\grams-carry.json'), $manJson, $utf8)
    }
    function Invoke-RgChild([string[]]$argv) {
      $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @argv
      return [pscustomobject]@{ Rc = $LASTEXITCODE; Text = (@($o) -join "`n") }
    }
    $tA = Join-Path $wt 'good'
    New-RgTree $tA $true
    $idxPath = Join-Path $tA 'recipes-db.json'
    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($idxPath))
    $d1 = Invoke-RgChild @('-Root', $tA)
    $same = [string]::Equals($before, [Convert]::ToBase64String([IO.File]::ReadAllBytes($idxPath)), [StringComparison]::Ordinal)
    Chk 'MUST FIRE  loaded FROM DISK, a dry run plans both carries (drained + reviewed) and writes nothing' ($d1.Rc -eq 0 -and $same -and $d1.Text -match 'recipes-db grams sync: 2 weight') ("rc={0} unchanged={1} :: {2}" -f $d1.Rc, $same, ($d1.Text -split "`n" | Select-Object -First 3) -join ' | ')
    $d2 = Invoke-RgChild @('-Root', $tA, '-Apply')
    $afterA = Ing2 ([IO.File]::ReadAllText($idxPath)) 'arroz' 'Sweet Whole Kernel Corn'
    $afterS = Ing2 ([IO.File]::ReadAllText($idxPath)) 'salty' 'Salt'
    Chk '-Apply from disk writes both: corn 695, salt 42 with its new label, a backup beside it' ($d2.Rc -eq 0 -and [double]$afterA.grams -eq 695 -and [double]$afterS.grams -eq 42 -and [string]$afterS.buy -eq $newSalt -and (Test-Path -LiteralPath ($idxPath + '.bak-gramsync'))) ("rc={0} corn={1} salt={2}" -f $d2.Rc, $afterA.grams, $afterS.grams)
    $tB = Join-Path $wt 'blind'
    New-RgTree $tB $false
    $bIdx = Join-Path $tB 'recipes-db.json'
    $bBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($bIdx))
    $d3 = Invoke-RgChild @('-Root', $tB, '-Apply')
    $bSame = [string]::Equals($bBefore, [Convert]::ToBase64String([IO.File]::ReadAllBytes($bIdx)), [StringComparison]::Ordinal)
    Chk 'MUST FIRE  a package table that loads EMPTY is exit 3 and writes nothing, even under -Apply' ($d3.Rc -eq 3 -and $bSame -and $d3.Text -match 'BLIND') ("rc={0} unchanged={1}" -f $d3.Rc, $bSame)
  } finally {
    Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
  }

  $EXPECTED = 20
  if ($ran -ne $EXPECTED) { Write-Output ("FAIL  the suite ran {0} case(s) and declares {1}" -f $ran, $EXPECTED); $fail++ }
  if ($fail -eq 0) { Write-Output ("SYNC-RECIPESDB-GRAMS SELF-TEST PASS ({0} cases)" -f $ran); exit 0 }
  Write-Output ("SYNC-RECIPESDB-GRAMS SELF-TEST FAIL: {0} case(s)" -f $fail); exit 1
}

$dbPath = Join-Path $mp 'recipes-db.json'
$specMap = Get-SpecGramMap (Join-Path $mp 'db\recipes')
$ev = Get-GramEvidence $mp
Write-Output ("  evidence: {0} drained can weight(s) from db\densities.json, {1} package weight(s) from db\ingredients.json{2}" -f $ev.CanG.Count, $ev.PkgG.Count, $(if ($ev.Manifest) { ", {0} reviewed row(s) from out\grams-carry.json" -f $ev.Manifest.Count } else { ', no reviewed manifest' }))
if ($ev.CanG.Count -eq 0 -or $ev.PkgG.Count -eq 0) {
  Write-Output 'recipes-db grams sync: BLIND - an evidence table loaded EMPTY, so the drained class cannot fire and every row would read "a person decides it". Nothing written.'
  exit 3
}
$st = Read-SpecText $dbPath
$res = Sync-RecipesDbGrams -Raw $st.Text -SpecGrams $specMap -CanG $ev.CanG -PkgG $ev.PkgG -Manifest $ev.Manifest
Write-Output ("recipes-db grams sync: {0} weight(s){1}" -f $res.changed, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))
foreach ($g in ($res.changes | Group-Object Class | Sort-Object Name)) { Write-Output ("    class {0,-16} {1}" -f $g.Name, $g.Count) }
foreach ($c in $res.changes) {
  $lab = if ($null -ne $c.NewBuy) { " and buy '{0}' -> '{1}'" -f $c.OldBuy, $c.NewBuy } else { '' }
  Write-Output ("    {0,-46} {1,-24} {2} g -> {3} g{4}" -f $c.Slug, $c.Item, $c.OldG, $c.NewG, $lab)
}
if ($res.drift.Count) {
  Write-Output ("  DISAGREEMENTS this script will not rewrite ({0}):" -f $res.drift.Count)
  foreach ($d in $res.drift) { Write-Output ('    ' + $d) }
}
if ($Apply -and $res.changed -gt 0) {
  Copy-Item -LiteralPath $dbPath -Destination ($dbPath + '.bak-gramsync') -Force
  Write-SpecText -Path $dbPath -Text $res.text -Bom $st.Bom      # parse-verifies before it writes, and keeps the BOM state
  Write-Output '  written (backup -> recipes-db.json.bak-gramsync). NEXT: meal-prep\gen-planner-data.ps1, then engine\audit-published-macros.ps1.'
}
exit 0
