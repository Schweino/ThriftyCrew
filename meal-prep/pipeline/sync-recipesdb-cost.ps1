<#
  sync-recipesdb-cost.ps1 - carry the COST BLOCK from the specs into recipes-db.json.

  WHY THIS EXISTS (founding bug: 2026-08-04, written 2026-08-04).
  db\recipes\<slug>.json is where a recipe's cost is AUTHORED (engine\cost-recipes.ps1 writes it, the
  reanchor scripts re-derive the display fields from it). recipes-db.json keeps its own copy of six of
  those numbers, written once by update-recipes-db.ps1 at import time and never refreshed after. On
  2026-07-25 19:41 the R300 merge wrote 299 rows whose ENTIRE cost block was panang-chicken-curry's
  (1.83 / 25.67 / 31.57 / 2.26 / 18.75 / 50.32); the R300 specs were recost per-recipe at 2026-07-26
  05:20 and nothing carried that back. 403 of 513 rows were still stale ten days later, mean gap $0.63,
  worst $4.31. Nothing in the estate said so: engine\audit-db-agreement.ps1 compared slug and protein.

  THIS IS A DERIVED-COPY REFRESH, NOT A JUDGEMENT CALL. Unlike the buy LABELS that
  sync-recipesdb-buy.ps1 carries - reader-facing text where "the spec is the source of truth" is a rule
  about authoring and not a licence to overwrite - a recipes-db cost number has exactly one legitimate
  value: the spec's. SPEC-SCHEMA.md names it a copy, update-recipes-db.ps1 writes it straight off
  $s['cost_per_serving'], and no other process may set it. So every disagreement is carried, with one
  gate: the SPEC's cost block must satisfy its own arithmetic before it is allowed to overwrite anything.
  A spec whose cost_per_serving is not cost_batch/14 is broken at the source, and an automated sync that
  copied it anyway would launder a bad number into the index and call the result agreement.

  BASIS WARNING - READ BEFORE POINTING A SURFACE AT THIS FIELD. cost_per_serving is the UTILIZATION
  basis: cost_batch/14, counting only the grams this recipe consumes out of each package. It is NOT what
  a shopper pays. The whole-package numbers live in pipeline\v2-perserving.json (everyday_ps at baseline
  prices, cheapest_ps across the board's stores) and that manifest - not this field - is what every site
  surface reads: build-hub-grid, build-card2, build-stretcher-data, top5, the rotation. Keeping this copy
  honest keeps the index a faithful mirror of the specs; it does not make it a price.

  Read-only unless -Apply.
  Usage: .\sync-recipesdb-cost.ps1 [-Apply]   |   .\sync-recipesdb-cost.ps1 -SelfTest
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path $mp 'lib\json-db-io.ps1')
# Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage, and both files the partial-cost
# gate reads below are written BOM-less. Loaded unconditionally so the gate cannot fail open on a mangled
# slug name. grocery\audit-json-readers.ps1 is the ratchet that holds this estate-wide.
if (-not (Get-Command Read-JsonFile -ErrorAction SilentlyContinue)) { . (Join-Path (Split-Path $mp -Parent) 'lib\json-io.ps1') }

# The six numbers recipes-db keeps its own copy of, in the order update-recipes-db.ps1 writes them.
$script:COST_FIELDS = @('cost_per_serving','cost_batch','cost_batch_true','cost_per_serving_true','cost_pantry_add','cost_first_run')

function Format-CostNumber([double]$v) {
    # Exactly what update-recipes-db.ps1's N() writes, so a synced row is byte-identical to an imported
    # one and a later re-import produces no diff. Invariant culture: a comma decimal separator would
    # make the file unparseable on a non-US machine.
    return ([double]$v).ToString([Globalization.CultureInfo]::InvariantCulture)
}

# MOVED TO lib\json-db-io.ps1 (2026-08-29). Get-JsonNumberSpan lived here, but it is generic JSON span
# arithmetic with nothing cost-specific about it, and sync-recipesdb-macros.ps1 needed exactly the same
# span logic to patch the per_serving / batch blocks. Copying it would have been a second copy of the same
# arithmetic - the trap this file's own sibling header names ("the two-copies-of-the-same-math blind
# spot is a documented board trap"). This script already dot-sources the lib, so it simply gets it there.

function Test-CostBlockCoherent {
    <#
      The gate. Returns '' when the spec's cost block may be carried, else the reason it may not.
      These are spec-guards.ps1's own cost invariants, re-stated here so this script can refuse a broken
      spec WITHOUT depending on the guard having been run. Pure, so every refusal is self-testable.
    #>
    param([Parameter(Mandatory)]$C)
    foreach ($k in $script:COST_FIELDS) {
        if ($null -eq $C.$k) { return "the spec has no $k" }
    }
    $b = [double]$C.cost_batch; $t = [double]$C.cost_batch_true
    $pa = [double]$C.cost_pantry_add; $fr = [double]$C.cost_first_run
    if ($b -le 0) { return 'the spec states a non-positive cost_batch' }
    if ([math]::Abs([double]$C.cost_per_serving - [math]::Round($b / 14, 2)) -gt 0.005) { return 'cost_per_serving is not cost_batch/14' }
    if ([math]::Abs([double]$C.cost_per_serving_true - [math]::Round($t / 14, 2)) -gt 0.005) { return 'cost_per_serving_true is not cost_batch_true/14' }
    if ($t -lt $b - 0.005) { return 'cost_batch_true is below cost_batch' }
    if ($pa -lt 0) { return 'cost_pantry_add is negative' }
    if ([math]::Abs($fr - ($t + $pa)) -gt 0.005) { return 'cost_first_run is not cost_batch_true + cost_pantry_add' }
    return ''
}

function Get-SpecCostMap {
    <# slug -> the six authored numbers, straight off the specs. #>
    param([Parameter(Mandatory)][string]$SpecDir)
    $map = @{}
    foreach ($f in @(Get-ChildItem (Join-Path $SpecDir '*.json') | Where-Object { $_.Name -ne '_index.json' })) {
        $spec = $null
        try { $spec = (Read-SpecText $f.FullName).Text | ConvertFrom-Json } catch { continue }
        $o = [ordered]@{}
        foreach ($k in $script:COST_FIELDS) {
            $o[$k] = if ($spec.PSObject.Properties.Name -contains $k) { $spec.$k } else { $null }
        }
        $map[$f.BaseName] = [pscustomobject]$o
    }
    return $map
}

function Test-PartialCostSyncable {
    <#
      THE FIRST-PUBLISH RULE, MADE STANDING (2026-09-20, queue 2026-09-19-d240fd).
      Returns '' when this slug's cost may be carried, else the reason it may not.

      meal-prep\pipeline\wave-preaudit.ps1:243-244 already refuses a WAVE recipe whose costed row has
      lines_unpriced != 0, because "the published cost EXCLUDES an ingredient the reader must buy". It runs
      at FIRST publish and nothing re-applied it to a recipe that is ALREADY LIVE when a later recost loses a
      line. On 2026-09-20 turkey-wild-rice-casserole - live, paid, visible - recosted with its TITLE
      ingredient missing: $2.21 a serving against a true $3.42, a 35% understatement on the reader's number.
      It stayed off the page only by an accident of composition (compute-v2-perserving skipped the recipe,
      which is itself an alert, and sync/propagate are hand runs). An accident is not a gate.

      PURE, so every refusal is self-testable. A slug that is NOT published is not refused: it is not on a
      page, and wave-preaudit owns it at first publish. A slug with no costed row is not refused either -
      absence of evidence is not evidence of a partial cost, and the sync's job is the six authored numbers.
    #>
    param([string]$Slug, $Published, $UnpricedBySlug)
    if (-not $Published -or -not $Published.ContainsKey($Slug)) { return '' }
    if (-not $UnpricedBySlug -or -not $UnpricedBySlug.ContainsKey($Slug)) { return '' }
    $n = [int]$UnpricedBySlug[$Slug]
    if ($n -le 0) { return '' }
    return ("lines_unpriced is $n - a LIVE recipe's cost that excludes an ingredient the reader must buy may not sync (wave-preaudit's first-publish rule, now standing)")
}

function Sync-RecipesDbCost {
    <# Pure text in, text out, so the self-test drives the same splice path the live run does. #>
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][hashtable]$SpecCost,
        $Published = $null,
        $UnpricedBySlug = $null
    )
    $db = $Raw | ConvertFrom-Json
    $changes = New-Object System.Collections.Generic.List[object]
    $drift = New-Object System.Collections.Generic.List[string]
    $absent = New-Object System.Collections.Generic.List[string]
    $refused = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($db.recipes)) {
        $slug = [string]$r.slug
        if (-not $SpecCost.ContainsKey($slug)) { $drift.Add("$slug : in recipes-db but has no spec"); continue }
        $partial = Test-PartialCostSyncable -Slug $slug -Published $Published -UnpricedBySlug $UnpricedBySlug
        if ($partial) { $refused.Add("$slug : $partial"); continue }
        $want = $SpecCost[$slug]
        $why = Test-CostBlockCoherent $want
        if ($why) { $drift.Add("$slug : the SPEC cost block is not self-consistent ($why) - refusing to carry it"); continue }
        foreach ($k in $script:COST_FIELDS) {
            # A field recipes-db never carried is a SHAPE gap, not a value gap: 111 pre-r300 rows have no
            # cost_pantry_add / cost_first_run at all. Adding keys is a structural rewrite of rows this
            # repair has no reason to touch, so it is named and left alone rather than silently invented.
            if ($r.PSObject.Properties.Name -notcontains $k) { $absent.Add("$slug :: $k"); continue }
            $have = [double]$r.$k
            $target = [double]$want.$k
            if ([math]::Abs($have - $target) -le 0.0000001) { continue }
            $changes.Add([pscustomobject]@{ Slug = $slug; Field = $k; Old = $have; New = $target })
        }
    }
    if ($changes.Count -eq 0) { return @{ changed = 0; text = $Raw; drift = @($drift.ToArray()); changes = @(); absent = @($absent.ToArray()); refused = @($refused.ToArray()) } }

    $text = $Raw
    # Group by slug: find the recipe row ONCE per slug via the brace walk Remove-RecipeRow uses, patch
    # every field inside it, then re-find for the next slug (offsets shift as we splice). A bare search
    # for "cost_per_serving" in a 3.9 MB file would hit the first recipe every time.
    foreach ($g in ($changes | Group-Object Slug)) {
        $slug = $g.Name
        $anchor = '"' + $slug + '"'
        $si = $text.IndexOf($anchor)
        if ($si -lt 0) { throw "sync: slug not found: $slug" }
        if ($text.IndexOf($anchor, $si + 1) -ge 0) { throw "sync: slug not unique: $slug" }
        $depth = 0; $rowStart = -1
        for ($i = $si; $i -ge 0; $i--) { $c = $text[$i]; if ($c -eq '}') { $depth++ } elseif ($c -eq '{') { if ($depth -eq 0) { $rowStart = $i; break } else { $depth-- } } }
        $depth = 0; $rowEnd = -1
        for ($i = $si; $i -lt $text.Length; $i++) { $c = $text[$i]; if ($c -eq '{') { $depth++ } elseif ($c -eq '}') { if ($depth -eq 0) { $rowEnd = $i; break } else { $depth-- } } }
        if ($rowStart -lt 0 -or $rowEnd -lt 0) { throw "sync: brace match failed for $slug" }
        $row = $text.Substring($rowStart, $rowEnd - $rowStart + 1)
        if (($row -split '"slug"').Count -ne 2) { throw "sync: row spans !=1 slug for $slug (abort)" }

        # Resolve every field to a span FIRST, then splice from the last offset backwards so the earlier
        # offsets stay valid. Find-JsonValueStart matches the closing quote of the key, so cost_batch
        # cannot match cost_batch_true and cost_per_serving cannot match cost_per_serving_true.
        $todo = New-Object System.Collections.Generic.List[object]
        foreach ($ch in $g.Group) {
            $at = Find-JsonValueStart -Raw $row -Key $ch.Field
            if ($at -lt 0) { throw ("sync: $slug has no $($ch.Field) key") }
            if ((Find-JsonValueStart -Raw $row -Key $ch.Field -Nth 2) -ge 0) { throw ("sync: $slug has $($ch.Field) twice (abort)") }
            $sp = Get-JsonNumberSpan -Raw $row -Start $at
            $cur = [double]$row.Substring($sp.Start, $sp.End - $sp.Start + 1)
            if ([math]::Abs($cur - [double]$ch.Old) -gt 0.0000001) { throw ("sync: $slug :: $($ch.Field) is $cur, expected $($ch.Old)") }
            $todo.Add([pscustomobject]@{ Span = $sp; Ch = $ch })
        }
        foreach ($t in @($todo | Sort-Object { $_.Span.Start } -Descending)) {
            $sp = $t.Span
            $row = $row.Substring(0, $sp.Start) + (Format-CostNumber $t.Ch.New) + $row.Substring($sp.End + 1)
        }
        $null = $row | ConvertFrom-Json    # the patched row must still parse on its own
        $text = $text.Substring(0, $rowStart) + $row + $text.Substring($rowEnd + 1)
    }
    return @{ changed = $changes.Count; text = $text; drift = @($drift.ToArray()); changes = @($changes.ToArray()); absent = @($absent.ToArray()); refused = @($refused.ToArray()) }
}

if ($SelfTest) {
    $fail = 0
    function Chk([string]$label, [bool]$cond, [string]$got) {
        if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
    }
    # ---------------------------------------------------------------------------------------------
    # FROZEN FIXTURE - the founding bug, 2026-08-04. Every number here is real.
    #
    #   stamped-a / stamped-b   carry panang-chicken-curry's ENTIRE cost block, which is what 299 R300
    #                           rows actually held. Two of them, because a splice that is not row-scoped
    #                           patches the first row twice and leaves the second stale - and with an
    #                           identical block on both rows that failure is invisible in a spot check.
    #   panang                  is the recipe those numbers belong to. It must come out UNTOUCHED: the
    #                           bug is indistinguishable from correctness on exactly one row, and a
    #                           repair that "fixes" it has proved it is not reading the spec at all.
    #   legacy                  is PRETTY-PRINTED with two spaces after each colon and carries only the
    #                           two cost fields the pre-r300 rows really have. The buy sync's first
    #                           version matched a compact shape and silently found nothing on these.
    #   broken                  has a spec whose cost_per_serving is not cost_batch/14. The db side is
    #                           wrong too, so a blind sync would "fix" it by copying a broken spec.
    # ---------------------------------------------------------------------------------------------
    $fx = @'
{"recipes":[
{"slug":"stamped-a","name":"Stamped A","cost_per_serving":1.83,"cost_batch":25.67,"cost_batch_true":31.57,"cost_per_serving_true":2.26,"cost_pantry_add":18.75,"cost_first_run":50.32,"notes":"R300 build 2026-07-25"},
{"slug":"stamped-b","name":"Stamped B","cost_per_serving":1.83,"cost_batch":25.67,"cost_batch_true":31.57,"cost_per_serving_true":2.26,"cost_pantry_add":18.75,"cost_first_run":50.32,"notes":"R300 build 2026-07-25"},
{"slug":"panang","name":"Panang","cost_per_serving":1.83,"cost_batch":25.67,"cost_batch_true":31.57,"cost_per_serving_true":2.26,"cost_pantry_add":18.75,"cost_first_run":50.32,"notes":"R300 build 2026-07-25"},
{"slug":"broken","name":"Broken","cost_per_serving":1.83,"cost_batch":25.67,"cost_batch_true":31.57,"cost_per_serving_true":2.26,"cost_pantry_add":18.75,"cost_first_run":50.32,"notes":"R300 build 2026-07-25"},
{
    "slug":  "legacy",
    "name":  "Legacy",
    "cost_per_serving":  2.45,
    "cost_batch":  32.89,
    "cost_batch_true":  40.11,
    "cost_per_serving_true":  2.87,
    "published":  "2026-07-19"
}
]}
'@
    function CB($b, $t, $pa, $fr) {
        [pscustomobject]@{ cost_per_serving = [math]::Round($b / 14, 2); cost_batch = $b; cost_batch_true = $t
                           cost_per_serving_true = [math]::Round($t / 14, 2); cost_pantry_add = $pa; cost_first_run = $fr }
    }
    $specCost = @{
        # soto-betawi's real block - the worst gap of the 403 ($1.83 shown against $6.14 authored)
        'stamped-a' = CB 85.95 102.28 15.41 117.69
        'stamped-b' = CB 84.54  96.16  9.60 105.76      # filipino-beef-caldereta's real block
        'panang'    = CB 25.67  31.57 18.75  50.32      # the row the stamped value legitimately belongs to
        'legacy'    = CB 30.10  38.00  0.00  38.00      # a real drift on a pre-r300 shaped row
        'broken'    = [pscustomobject]@{ cost_per_serving = 9.99; cost_batch = 25.67; cost_batch_true = 31.57
                                         cost_per_serving_true = 2.26; cost_pantry_add = 18.75; cost_first_run = 50.32 }
    }
    $r = Sync-RecipesDbCost -Raw $fx -SpecCost $specCost
    $out = $r.text | ConvertFrom-Json
    function Row($o, $s) { return @($o.recipes | Where-Object { $_.slug -eq $s }) }
    $a = Row $out 'stamped-a'; $b = Row $out 'stamped-b'; $p = Row $out 'panang'
    $l = Row $out 'legacy';    $bk = Row $out 'broken'
    $dr = ($r.drift -join ' || ')

    Chk 'MUST FIRE  a stamped row is re-anchored to its own spec (1.83 -> 6.14)' ([double]$a.cost_per_serving -eq 6.14) ([string]$a.cost_per_serving)
    Chk 'MUST FIRE  the whole block moves together, not just the headline number' (([double]$a.cost_batch -eq 85.95) -and ([double]$a.cost_batch_true -eq 102.28) -and ([double]$a.cost_per_serving_true -eq 7.31) -and ([double]$a.cost_pantry_add -eq 15.41) -and ([double]$a.cost_first_run -eq 117.69)) ("batch=$($a.cost_batch) true=$($a.cost_batch_true) cpsT=$($a.cost_per_serving_true) add=$($a.cost_pantry_add) first=$($a.cost_first_run)")
    Chk 'MUST FIRE  the SECOND row holding the identical stamped block is patched too, not skipped' ([double]$b.cost_per_serving -eq 6.04) ([string]$b.cost_per_serving)
    Chk 'MUST FIRE  a PRETTY-PRINTED pre-r300 row is patched too (the shape-regex blind spot)' (([double]$l.cost_per_serving -eq 2.15) -and ([double]$l.cost_batch -eq 30.1)) ("cps=$($l.cost_per_serving) batch=$($l.cost_batch)")
    Chk 'MUST NOT FIRE the one row the stamped value BELONGS to is left untouched' (([double]$p.cost_per_serving -eq 1.83) -and (@($r.changes | Where-Object { $_.Slug -eq 'panang' }).Count -eq 0)) ([string]$p.cost_per_serving)
    Chk 'CLEAN TWIN an incoherent SPEC block is refused and reported, never copied in' (([double]$bk.cost_per_serving -eq 1.83) -and ($dr -match 'not self-consistent')) ([string]$bk.cost_per_serving + ' / ' + $dr)
    Chk 'CLEAN TWIN a field the row never carried is NAMED, not invented' ((($l.PSObject.Properties.Name -notcontains 'cost_first_run')) -and (($r.absent -join '|') -match 'legacy :: cost_first_run')) (($r.absent -join '|'))
    Chk 'the file still parses and keeps all five rows' (@($out.recipes).Count -eq 5) ("rows=" + @($out.recipes).Count)
    # stamped-a 6 + stamped-b 6 + legacy 4 (it has no pantry_add/first_run) = 16
    Chk 'exactly sixteen field changes across three rows' ($r.changed -eq 16) ("changed=" + $r.changed)
    Chk 'every change names a slug that had a real disagreement' ((@($r.changes | Group-Object Slug).Count -eq 3) -and (@($r.changes | Where-Object { $_.Slug -eq 'broken' }).Count -eq 0)) ((@($r.changes | Group-Object Slug | ForEach-Object { $_.Name }) -join ','))
    $r2 = Sync-RecipesDbCost -Raw $r.text -SpecCost $specCost
    Chk 'idempotent - a second pass changes nothing' ($r2.changed -eq 0) ("changed=" + $r2.changed)
    # ---- THE STANDING PARTIAL-COST RULE (2026-09-20, queue 2026-09-19-d240fd) ------------------------
    # MUST FIRE, built from the real row: turkey-wild-rice-casserole is LIVE (published-hashes) and its
    # 2026-09-20 costed row reads lines_unpriced 1 because the engine dropped Wild Rice - 855 g, $16.94 a
    # batch, $1.21 a serving, costing it at $2.21 against a true $3.42. That cost may not reach the card.
    $pubFx = @{ 'stamped-a' = $true; 'panang' = $true }
    $unFx  = @{ 'stamped-a' = 1; 'panang' = 0 }
    $rp = Sync-RecipesDbCost -Raw $fx -SpecCost $specCost -Published $pubFx -UnpricedBySlug $unFx
    $rpRef = @($rp.refused | Where-Object { $_ })
    Chk 'MUST FIRE  a LIVE slug whose costed row has lines_unpriced 1 is REFUSED, named, and none of its six fields is written' (($rpRef.Count -eq 1) -and (($rpRef -join '|') -match 'stamped-a') -and (($rpRef -join '|') -match 'lines_unpriced is 1') -and (@($rp.changes | Where-Object { $_.Slug -eq 'stamped-a' }).Count -eq 0)) (($rpRef -join '|') + ' changes=' + @($rp.changes | Where-Object { $_.Slug -eq 'stamped-a' }).Count)
    # AT THE BAR AND ONE PAST IT (backlog I196): 0 is the bar, 1 is one unit of the comparison's resolution.
    $rb = Sync-RecipesDbCost -Raw $fx -SpecCost $specCost -Published $pubFx -UnpricedBySlug @{ 'stamped-a' = 0 }
    Chk 'MUST NOT FIRE lines_unpriced exactly 0 - the bar itself - is not a refusal, and the row still syncs' ((@($rb.refused | Where-Object { $_ }).Count -eq 0) -and (@($rb.changes | Where-Object { $_.Slug -eq 'stamped-a' }).Count -gt 0)) ('refused=' + @($rb.refused | Where-Object { $_ }).Count)
    # MUST NOT FIRE: an UNPUBLISHED slug with an unpriced line is not on a page; wave-preaudit owns it at
    # first publish, and refusing it here would block a wave the estate deliberately gates elsewhere.
    $ru = Sync-RecipesDbCost -Raw $fx -SpecCost $specCost -Published @{} -UnpricedBySlug @{ 'stamped-a' = 1 }
    Chk 'MUST NOT FIRE an UNPUBLISHED slug with an unpriced line is not refused here (wave-preaudit owns first publish)' ((@($ru.refused | Where-Object { $_ }).Count -eq 0) -and (@($ru.changes | Where-Object { $_.Slug -eq 'stamped-a' }).Count -gt 0)) ('refused=' + @($ru.refused | Where-Object { $_ }).Count)
    # CLEAN TWIN: the adjacent behaviour this change was most likely to break - every OTHER published slug
    # with a clean costed row still syncs exactly as before, and the refusal does not leak into drift.
    Chk 'CLEAN TWIN a published slug with lines_unpriced 0 still syncs all its fields, and no refusal lands in drift' ((@($rp.changes | Where-Object { $_.Slug -eq 'stamped-b' }).Count -gt 0) -and (($rp.drift -join '|') -notmatch 'lines_unpriced')) ('b=' + @($rp.changes | Where-Object { $_.Slug -eq 'stamped-b' }).Count + ' drift=' + ($rp.drift -join '|'))
    # CLEAN TWIN: with NEITHER map supplied (the shape every existing caller uses) nothing is refused.
    Chk 'MUST NOT FIRE with no published/unpriced maps at all, the sync refuses nothing - existing callers are unchanged' (@($r.refused | Where-Object { $_ }).Count -eq 0) ('refused=' + @($r.refused | Where-Object { $_ }).Count)
    # A row with no spec must be reported, never zeroed - [double]$null is 0 and would print $0.00 a bowl.
    $fx2 = '{"recipes":[{"slug":"orphan","name":"Orphan","cost_per_serving":3.10,"cost_batch":43.40,"cost_batch_true":50.00,"cost_per_serving_true":3.57,"cost_pantry_add":0,"cost_first_run":50.00}]}'
    $r3 = Sync-RecipesDbCost -Raw $fx2 -SpecCost $specCost
    Chk 'CLEAN TWIN an index row with no spec is reported, never zeroed' (($r3.changed -eq 0) -and (($r3.drift -join '|') -match 'has no spec')) ("changed=$($r3.changed) / " + ($r3.drift -join '|'))

    if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$dbPath = Join-Path $mp 'recipes-db.json'
$specCost = Get-SpecCostMap (Join-Path $mp 'db\recipes')
Write-Output ("specs read: {0}" -f $specCost.Count)
$raw = [System.IO.File]::ReadAllText($dbPath)
# THE TWO INPUTS THE STANDING RULE NEEDS (2026-09-20, queue 2026-09-19-d240fd): which slugs are LIVE, and
# which costed rows exclude a line the reader must buy. Both are read through Read-JsonFile, and a file this
# script cannot read leaves its map EMPTY - which refuses nothing and is stated, never silently assumed
# clean. A could-not-look must not settle the question, so the line below says which of the two it read.
$published = @{}
$unpriced = @{}
$phPath = Join-Path $mp 'db\published-hashes.json'
$cdPath = Join-Path $mp 'db\costed.json'
$phRead = $false; $cdRead = $false
try { $ph = Read-JsonFile $phPath; foreach ($p in $ph.PSObject.Properties) { $published[[string]$p.Name] = $true }; $phRead = $true } catch { $phRead = $false }
try { foreach ($c in @(Read-JsonFile $cdPath)) { if ($c -and $c.slug) { $unpriced[[string]$c.slug] = [int]$c.lines_unpriced } }; $cdRead = $true } catch { $cdRead = $false }
Write-Output ("partial-cost gate inputs: published-hashes {0} ({1} slug(s)), costed {2} ({3} row(s))" -f $(if ($phRead) { 'read' } else { 'COULD NOT READ' }), $published.Count, $(if ($cdRead) { 'read' } else { 'COULD NOT READ' }), $unpriced.Count)
$res = Sync-RecipesDbCost -Raw $raw -SpecCost $specCost -Published $published -UnpricedBySlug $unpriced
$rowsTouched = @($res.changes | Group-Object Slug).Count
Write-Output ("recipes-db cost sync: {0} field(s) across {1} row(s){2}" -f $res.changed, $rowsTouched, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))
foreach ($g in ($res.changes | Group-Object Field | Sort-Object Name)) { Write-Output ("    field {0,-24} {1}" -f $g.Name, $g.Count) }
$hd = @($res.changes | Where-Object { $_.Field -eq 'cost_per_serving' } | Sort-Object { -[math]::Abs($_.New - $_.Old) })
Write-Output ("  largest per-serving corrections:")
foreach ($c in ($hd | Select-Object -First 10)) { Write-Output ("    {0,-46} {1,7:0.00} -> {2,7:0.00}" -f $c.Slug, $c.Old, $c.New) }
if ($hd.Count -gt 10) { Write-Output ("    ... and {0} more rows whose per-serving number moves" -f ($hd.Count - 10)) }
if ($res.absent.Count) {
    $af = @($res.absent | ForEach-Object { ($_ -split ' :: ')[1] } | Group-Object | Sort-Object Name)
    Write-Output ("  SHAPE GAP - fields recipes-db never carried on some rows (named, not invented): " + (($af | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '))
}
if ($res.drift.Count) {
    Write-Output ("  DRIFT this script will not rewrite ({0}):" -f $res.drift.Count)
    foreach ($d in ($res.drift | Select-Object -First 15)) { Write-Output ('    ' + $d) }
    if ($res.drift.Count -gt 15) { Write-Output ("    ... and {0} more" -f ($res.drift.Count - 15)) }
}
if ($Apply -and $res.changed -gt 0) {
    Copy-Item $dbPath ($dbPath + '.bak-costsync') -Force
    $chk = $res.text | ConvertFrom-Json          # parse-verify before writing
    if (@($chk.recipes).Count -ne @(($raw | ConvertFrom-Json).recipes).Count) { throw 'sync: recipe count changed - refusing to write' }
    [System.IO.File]::WriteAllText($dbPath, $res.text)
    Write-Output ("  written (backup -> recipes-db.json.bak-costsync)")
}
# THE REFUSAL IS SPOKEN AND IT IS NON-ZERO. A run that declined to act must not be indistinguishable from a
# run with nothing to do - and a partial cost reaching a live card is a wrong number on a paid page.
$refusedList = @($res.refused | Where-Object { $_ })
if ($refusedList.Count -gt 0) {
    Write-Output ("  PARTIAL-COST REFUSED ({0} live recipe(s)) - their cost was NOT synced; the page keeps its last full cost:" -f $refusedList.Count)
    foreach ($x in $refusedList) { Write-Output ('    ' + $x) }
    Write-Output ("sync-recipesdb-cost: REFUSED {0} live slug(s) whose costed row excludes a line the reader must buy. Fix the price basis (or hold the recipe); do not sync around it." -f $refusedList.Count)
    exit 2
}
Write-Output 'sync-recipesdb-cost: OK - no live recipe was carrying a partial cost'
exit 0
