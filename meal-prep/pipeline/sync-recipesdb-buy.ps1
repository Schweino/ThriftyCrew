<#
  sync-recipesdb-buy.ps1 - carry an ingredient LABEL repair from the specs into recipes-db.json.

  WHY THIS EXISTS. db\recipes\<slug>.json is the source of truth, but recipes-db.json keeps its own copy
  of every ingredient's buy amount, and planner-data.js is generated from THAT copy - so the Meal Plan
  Builder's merged grocery list reads the db, not the specs. A label repair that stops at the specs and
  the cards leaves the planner showing the old text indefinitely, and nothing in the estate would say so:
  audit-db-agreement compares slug and protein, not labels.

  update-recipes-db.ps1 -Replace is the general path, but it REBUILDS every field of every row it
  touches (including re-resolving item_id through ingredient-map). For a repair that changes one token
  in one field that is a large blast radius and an unreadable diff. This patches just the buy strings,
  brace-scoped to the recipe row and then to the ingredient inside it, leaving every other byte alone.

  IT CARRIES ONLY NAMED, PROVEN CLASSES ACROSS. Every other disagreement is REPORTED, never rewritten,
  because "the spec is the source of truth" is a rule about where a value is AUTHORED, not a licence to
  overwrite live reader-facing text with whatever a file happens to contain today. A carry class has to
  say, in arithmetic, why the db side is wrong and why the spec side is right. Two exist:

    unitless-count   The db label states no unit at all and the spec's does ("2.3" -> "2.3 onions").
                     Carrying it cannot change a quantity; it can only add the missing word.

    scaled-note      The db label carries a writer's authoring note ("1 (scaled ~3)") - a note-to-self
                     about scaling a base recipe up, with the UNSCALED amount still in front of it. It
                     is not a false measurement, it is not a measurement at all, which is why neither
                     class above can see it and why it needs no arithmetic to condemn. What the class
                     still has to prove is that the SPEC side was reviewed, and it proves that the same
                     way the cook-measure class does - by refusing to act on its own judgement. The row
                     must appear, byte for byte in both its old and new value, in the carry manifest
                     out\scaled-note-carry.json that repair-scaled-notes.ps1 writes when it applies. So
                     this class can only ever finish a repair that actually ran, on the exact rows it
                     touched; with no manifest it carries nothing.

    cook-measure     The db label is a PACKAGE noun that repair-cook-measures.ps1 proved false
                     ("2 cans" against 910 g of beans) and the spec holds that repair's own output
                     ("5 1/4 cups"). Four things must all hold before a row qualifies, and the last is
                     the one that matters: the spec value must be BYTE-IDENTICAL to what
                     Get-CookMeasure writes from the db value and the recipe's grams. That is what
                     separates "the 2026-08-02 repair reached the specs and stopped" from "somebody
                     edited a spec", and it means this class can only ever finish a repair that already
                     happened - it can never invent a number or ratify a hand edit.

    range-buy        The db label states a RANGE where the quantity belongs ("2-3 cloves, minced") and
                     the spec holds repair-range-buy.ps1's resolution of it ("8 cloves, minced"). A
                     range is condemnable without weighing anything - it names two quantities where the
                     card can only mean one, and the serving widget moves only the first, so "2-3
                     cloves" doubles to "4-3 cloves" - which is why it needs no arithmetic test of its
                     own. Proof that the SPEC side was reviewed comes the same way the scaled-note class
                     gets it: the row must appear, byte for byte in both its old and new value, in
                     out\range-buy-carry.json, which repair-range-buy.ps1 writes when it applies. That
                     also carries its two hand-adjudicated labels without a second mechanism - a
                     manifest records what the repair DID, which is a superset of what it could derive.

    measure-vs-grams The db label states a perfectly well-formed measurement that the recipe does not use
                     ("Salt: 1/4 tsp" against 8 g) and the spec holds repair-measure-vs-grams.ps1's
                     rewrite of it ("1.5 tsp"). THIS CLASS HAS NO SHAPE. The other three announce
                     themselves in the string - a missing unit, a dash, "(scaled ~" - so each can be
                     recognised and then proved. This one looks exactly like a correct label, which is
                     why it survived every sweep to date and why Test-CmLabelTrue passes it as "not
                     provably false". So the manifest is not corroboration here, it is the entire
                     trigger: out\measure-vs-grams-carry.json, written by repair-measure-vs-grams.ps1
                     when it applies, and that repair only ever touched rows whose source recipe had
                     already been read and had settled that the LABEL was the wrong side. Absent
                     manifest, the class carries nothing at all.

  WHY A SECOND CLASS WAS NEEDED AT ALL (2026-08-04). repair-cook-measures.ps1 rewrote 462 ingredient
  labels across the specs and printed a slug list for a card rebuild, but it had no recipes-db step -
  and recipes-db keeps its own copy of every buy string, which is what gen-planner-data.ps1 reads. So
  the Meal Plan Builder's merged grocery list went on printing the pre-repair package nouns for two
  days. Nothing flagged it: engine\audit-db-agreement.ps1 compares slug and protein, not labels.

  Read-only unless -Apply.
  Usage: .\sync-recipesdb-buy.ps1 [-Apply]   |   .\sync-recipesdb-buy.ps1 -SelfTest
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path $mp 'lib\json-db-io.ps1')
. (Join-Path $here 'cook-measure-lib.ps1')

function Get-SpecBuyMap([string]$specDir) {
    <# slug -> @{ canonical item = <buy, grams, item> } straight off the specs. canon is the join key
       recipes-db uses (update-recipes-db writes scaler.canon, never the reader-facing rename), but the
       DENSITY lookup has to use the reader-facing `item`, because that is the name
       repair-cook-measures.ps1 itself passed to Get-CmDensity. Joining on one and weighing with the
       other would quietly compare against a different food's grams-per-cup. #>
    $map = @{}
    foreach ($f in @(Get-ChildItem (Join-Path $specDir '*.json') | Where-Object { $_.Name -ne '_index.json' })) {
        $spec = $null
        try { $spec = (Read-SpecText $f.FullName).Text | ConvertFrom-Json } catch { continue }
        if (-not $spec.scaler -or -not $spec.scaler.ing) { continue }
        $m = @{}
        foreach ($i in @($spec.scaler.ing)) {
            $canon = if ($i.PSObject.Properties.Name -contains 'canon' -and $i.canon) { [string]$i.canon } else { [string]$i.item }
            $g = if ($i.PSObject.Properties.Name -contains 'grams' -and $i.grams) { [double]$i.grams } else { 0 }
            $m[$canon] = [pscustomobject]@{ Buy = [string]$i.buy; Grams = $g; Item = [string]$i.item }
        }
        $map[$f.BaseName] = $m
    }
    return $map
}

function Get-BuyCarryClass {
    <#
      Name the repair class for one disagreeing label, or return '' with the reason it does not qualify.
      Pure, so every refusal below is a case the self-test can pin.

      The order of the cook-measure guards is the order of increasing strictness, and each one exists
      because passing it is NOT enough on its own:
        * grams must agree, or the two sides are not describing the same amount of food and no amount of
          label arithmetic means anything.
        * the db label must be provably FALSE. A package noun that equals the grams ("1 can" of a 411 g
          can of tomatoes) is a correct label; the spec differing from it is a question for a person, not
          a defect to carry.
        * the spec label must be TRUE. Never carry across a value that fails the same test the db failed.
        * the spec must be exactly what the repair writes. A spec that is true but different ("1/3 cup"
          where the repair would have written "1/2 cup") is a hand edit, and ratifying hand edits through
          an automated sync is how a tool stops being a repair and starts being an unreviewed writer.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Have,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Item,
        [double]$SpecGrams = 0,
        [double]$DbGrams = -1,
        $Dens = $null,
        [AllowEmptyString()][string]$Slug = '',
        $Carry = $null,                 # slug|item -> @{ Old; New } from out\scaled-note-carry.json
        $RangeCarry = $null,            # slug|item -> @{ Old; New } from out\range-buy-carry.json
        $MeasureCarry = $null           # slug|item -> @{ Old; New } from out\measure-vs-grams-carry.json
    )
    if (($Have -notmatch '[A-Za-z]') -and ($Target -match '[A-Za-z]')) {
        return [pscustomobject]@{ Class = 'unitless-count'; Reason = '' }
    }
    # range-buy. Checked before the cook-measure guards for the same reason scaled-note is: Get-CmUnit's
    # pattern is anchored and cannot read a unit past a dash, so "2-3 cloves" reports no unit at all and
    # Test-CmLabelTrue passes it as "not provably false". It would fall through every guard below and be
    # reported as an unresolvable question forever.
    if (Test-RangeBuy -Buy $Have) {
        if (-not $RangeCarry) {
            return [pscustomobject]@{ Class = ''; Reason = 'db label states a range, but no carry manifest is present - run repair-range-buy.ps1 -Apply first' }
        }
        $rk = $Slug + '|' + $Item
        if (-not $RangeCarry.ContainsKey($rk)) {
            return [pscustomobject]@{ Class = ''; Reason = 'db label states a range that no repair run claims - a person decides this one' }
        }
        $rc = $RangeCarry[$rk]
        # BOTH sides must match the manifest. Old proves the db row has not moved since the repair ran;
        # New proves the spec holds that run's own output and not a later hand edit.
        if ([string]$rc.Old -ne $Have) {
            return [pscustomobject]@{ Class = ''; Reason = ("the db label has changed since the repair ran (manifest expected '{0}')" -f $rc.Old) }
        }
        if ([string]$rc.New -ne $Target) {
            return [pscustomobject]@{ Class = ''; Reason = ("the spec is not what the repair wrote (that was '{0}') - looks hand-edited since" -f $rc.New) }
        }
        return [pscustomobject]@{ Class = 'range-buy'; Reason = '' }
    }
    # scaled-note. Checked before the cook-measure guards because an authoring note is not a measurement
    # and would fall through all of them as "not provably false" - which is how these seven rows sat in
    # recipes-db while the specs were already clean.
    if ($Have -match '\(scaled ~') {
        if (-not $Carry) {
            return [pscustomobject]@{ Class = ''; Reason = 'db label carries an authoring note, but no carry manifest is present - run repair-scaled-notes.ps1 -Apply first' }
        }
        $k = $Slug + '|' + $Item
        if (-not $Carry.ContainsKey($k)) {
            return [pscustomobject]@{ Class = ''; Reason = 'db label carries an authoring note that no repair run claims - a person decides this one' }
        }
        $c = $Carry[$k]
        # BOTH sides must match the manifest. Old proves the db row has not moved since the repair ran;
        # New proves the spec holds that run's own output and not a later hand edit.
        if ([string]$c.Old -ne $Have) {
            return [pscustomobject]@{ Class = ''; Reason = ("the db label has changed since the repair ran (manifest expected '{0}')" -f $c.Old) }
        }
        if ([string]$c.New -ne $Target) {
            return [pscustomobject]@{ Class = ''; Reason = ("the spec is not what the repair wrote (that was '{0}') - looks hand-edited since" -f $c.New) }
        }
        return [pscustomobject]@{ Class = 'scaled-note'; Reason = '' }
    }
    # measure-vs-grams. Checked before the cook-measure guards because this defect has NO shape to detect.
    # The other three classes announce themselves in the label - a missing unit, a dash, "(scaled ~". This
    # one is an ordinary, well-formed measurement that simply states a quantity the recipe does not use
    # ("Salt: 1/4 tsp" against 8 g), so Test-CmLabelTrue passes it as "not provably false" and it would
    # fall through every guard below and be reported as a question forever - which is exactly how it sat
    # in recipes-db while the specs were being repaired.
    #
    # So the TRIGGER here is the manifest itself rather than the string: a row is in this class only
    # because repair-measure-vs-grams.ps1 claims to have rewritten it, and that repair only ever touched
    # rows a source check had already decided. That keeps the rule the same as the other two - the sync
    # can FINISH a repair that actually ran, on the exact rows it touched, and can never ratify a hand
    # edit or fire on a spec nobody reviewed.
    if ($MeasureCarry) {
        $mk = $Slug + '|' + $Item
        if ($MeasureCarry.ContainsKey($mk)) {
            $mc = $MeasureCarry[$mk]
            # BOTH sides must match. Old proves the db row has not moved since the repair ran; New proves
            # the spec holds that run's own output and not a later hand edit.
            if ([string]$mc.Old -ne $Have) {
                return [pscustomobject]@{ Class = ''; Reason = ("the db label has changed since the repair ran (manifest expected '{0}')" -f $mc.Old) }
            }
            if ([string]$mc.New -ne $Target) {
                return [pscustomobject]@{ Class = ''; Reason = ("the spec is not what the repair wrote (that was '{0}') - looks hand-edited since" -f $mc.New) }
            }
            return [pscustomobject]@{ Class = 'measure-vs-grams'; Reason = '' }
        }
    }
    if (-not $Dens) { return [pscustomobject]@{ Class = ''; Reason = 'no densities loaded - cook-measure class not evaluated' } }
    if ($SpecGrams -le 0) { return [pscustomobject]@{ Class = ''; Reason = 'the spec states no grams' } }
    if ($DbGrams -lt 0) { return [pscustomobject]@{ Class = ''; Reason = 'the db row states no grams' } }
    if ([math]::Abs($DbGrams - $SpecGrams) -ge 0.5) {
        return [pscustomobject]@{ Class = ''; Reason = ("grams disagree too (db {0} vs spec {1}) - not a label repair" -f $DbGrams, $SpecGrams) }
    }
    if (Test-CmLabelTrue $Dens $Item $Have $SpecGrams) {
        return [pscustomobject]@{ Class = ''; Reason = 'the db label is not provably false - a person decides this one' }
    }
    if (-not (Test-CmLabelTrue $Dens $Item $Target $SpecGrams)) {
        return [pscustomobject]@{ Class = ''; Reason = 'the spec label is not provably true either' }
    }
    $regen = [string](Get-CookMeasure $Dens $Item $SpecGrams $Have)
    if ($regen -ne $Target) {
        return [pscustomobject]@{ Class = ''; Reason = ("the spec is not what the repair writes from '{0}' (that would be '{1}') - looks hand-edited" -f $Have, $regen) }
    }
    return [pscustomobject]@{ Class = 'cook-measure'; Reason = '' }
}

function Sync-RecipesDbBuy {
    <# Pure text in, text out, so the self-test drives the same splice path the live run does. #>
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][hashtable]$SpecBuy,
        $Dens = $null,
        $Carry = $null,
        $RangeCarry = $null,
        $MeasureCarry = $null
    )
    $db = $Raw | ConvertFrom-Json
    $changes = New-Object System.Collections.Generic.List[object]
    $drift = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($db.recipes)) {
        $slug = [string]$r.slug
        if (-not $SpecBuy.ContainsKey($slug)) { $drift.Add("$slug : in recipes-db but has no spec"); continue }
        $want = $SpecBuy[$slug]
        foreach ($ing in @($r.ingredients)) {
            $item = [string]$ing.item
            $have = [string]$ing.buy
            if (-not $want.ContainsKey($item)) { $drift.Add("$slug :: $item : in recipes-db but not in the spec's scaler"); continue }
            # The map value is either a bare buy string (grams unknown, so only the unitless class can
            # fire) or the full <buy, grams, item> record Get-SpecBuyMap builds.
            $w = $want[$item]
            $target = if ($w -is [string]) { [string]$w } else { [string]$w.Buy }
            $specG  = if ($w -is [string]) { 0 } else { [double]$w.Grams }
            $densNm = if ($w -is [string] -or -not $w.Item) { $item } else { [string]$w.Item }
            if ($have -eq $target) { continue }
            $dbG = if ($ing.PSObject.Properties.Name -contains 'grams' -and $null -ne $ing.grams) { [double]$ing.grams } else { -1 }
            $cls = Get-BuyCarryClass -Have $have -Target $target -Item $densNm -SpecGrams $specG -DbGrams $dbG -Dens $Dens -Slug $slug -Carry $Carry -RangeCarry $RangeCarry -MeasureCarry $MeasureCarry
            if (-not $cls.Class) {
                $drift.Add("$slug :: $item : db '$have' vs spec '$target' ($($cls.Reason))")
                continue
            }
            $changes.Add([pscustomobject]@{ Slug = $slug; Item = $item; Old = $have; New = $target; Class = $cls.Class })
        }
    }
    if ($changes.Count -eq 0) { return @{ changed = 0; text = $Raw; drift = @($drift.ToArray()); changes = @() } }

    $text = $Raw
    # Group by slug: find the recipe row ONCE per slug, patch every ingredient inside it, and re-find the
    # row for the next slug (offsets shift as we splice). Row lookup is the brace walk Remove-RecipeRow
    # uses - a bare search for "buy" in a 3.9 MB file would hit the first recipe every time.
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

        # Walk the ingredients array structurally rather than matching a key ORDER or a spacing style:
        # recipes-db is not uniformly formatted (the r300 rows were spliced in compact, the older rows
        # are pretty-printed with two spaces after the colon), so a shape regex silently matches nothing
        # on half the file - which is a repair that reports success and changes not one byte.
        $ingAt = Find-JsonValueStart -Raw $row -Key 'ingredients'
        if ($ingAt -lt 0) { throw "sync: no ingredients array in $slug" }
        $spans = @(Get-JsonArraySpans -Raw $row -OpenIndex $ingAt)
        # resolve every target to a span index first, then splice from the last backwards so offsets hold
        $todo = New-Object System.Collections.Generic.List[object]
        foreach ($ch in $g.Group) {
            $hits = @()
            for ($k = 0; $k -lt $spans.Count; $k++) {
                $el = $row.Substring($spans[$k].Start, $spans[$k].End - $spans[$k].Start + 1)
                $o = $el | ConvertFrom-Json
                if ([string]$o.item -eq [string]$ch.Item -and [string]$o.buy -eq [string]$ch.Old) { $hits += $k }
            }
            if ($hits.Count -ne 1) { throw ("sync: $slug :: $($ch.Item) matched $($hits.Count) ingredient objects (expected 1)") }
            $todo.Add([pscustomobject]@{ K = $hits[0]; Ch = $ch })
        }
        foreach ($t in @($todo | Sort-Object K -Descending)) {
            $sp = $spans[$t.K]
            $el = $row.Substring($sp.Start, $sp.End - $sp.Start + 1)
            $bAt = Find-JsonValueStart -Raw $el -Key 'buy'
            if ($bAt -lt 0) { throw ("sync: no buy key in $slug :: $($t.Ch.Item)") }
            $vs = Get-JsonStringSpan -Raw $el -OpenIndex $bAt
            $cur = $el.Substring($vs.Start, $vs.End - $vs.Start + 1)
            if ($cur -ne $t.Ch.Old) { throw ("sync: $slug :: $($t.Ch.Item) buy is '$cur', expected '$($t.Ch.Old)'") }
            $newEl = $el.Substring(0, $vs.Start) + $t.Ch.New + $el.Substring($vs.End + 1)
            $row = $row.Substring(0, $sp.Start) + $newEl + $row.Substring($sp.End + 1)
        }
        $text = $text.Substring(0, $rowStart) + $row + $text.Substring($rowEnd + 1)
    }
    return @{ changed = $changes.Count; text = $text; drift = @($drift.ToArray()); changes = @($changes.ToArray()) }
}

if ($SelfTest) {
    $fail = 0
    function Chk([string]$label, [bool]$cond, [string]$got) {
        if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
    }
    # FROZEN FIXTURE. Two things this pins, both of which actually bit on 2026-08-04:
    #   * alpha and beta both use Yellow Onion at the SAME count, so a splice that is not row-scoped
    #     patches the wrong recipe (or refuses, having found two matches).
    #   * delta is PRETTY-PRINTED with two spaces after each colon, which is how the pre-r300 rows are
    #     really stored. The first version of this script matched a compact key-order shape and found
    #     nothing on those rows - a repair that reports success and changes not one byte.
    $fx = @'
{"recipes":[
{"slug":"alpha","name":"Alpha","ingredients":[{"item":"Yellow Onion","grams":257,"buy":"2.3","item_id":"onions"},{"item":"Pork Loin","grams":2646,"buy":"5.75 lb","item_id":"pork-loin"}]},
{"slug":"beta","name":"Beta","ingredients":[{"item":"Yellow Onion","grams":257,"buy":"2.3","item_id":"onions"},{"item":"Rice","grams":648,"buy":"3.5 cups dry","item_id":"rice"}]},
{"slug":"gamma","name":"Gamma","ingredients":[{"item":"Celery","grams":192,"buy":"9 stalks","item_id":"celery"},{"item":"Jalapeno","grams":45,"buy":"1-2","item_id":"jalapenos"}]},
{
    "slug":  "delta",
    "name":  "Delta",
    "ingredients":  [
                        {
                            "item":  "Bay Leaves",
                            "grams":  1,
                            "buy":  "1",
                            "item_id":  "bay-leaves"
                        }
                    ]
}
]}
'@
    $specBuy = @{
        'alpha' = @{ 'Yellow Onion' = '2.3 onions'; 'Pork Loin' = '5.75 lb' }
        'beta'  = @{ 'Yellow Onion' = '2.3 onions'; 'Rice' = '3.5 cups dry' }
        'gamma' = @{ 'Celery' = '3.5 stalks'; 'Jalapeno' = '3 jalapenos' }  # one real disagreement, one repaired range
        'delta' = @{ 'Bay Leaves' = '1 leaf' }
    }
    $r = Sync-RecipesDbBuy -Raw $fx -SpecBuy $specBuy
    $out = $r.text | ConvertFrom-Json
    $a = @($out.recipes | Where-Object { $_.slug -eq 'alpha' }).ingredients
    $b = @($out.recipes | Where-Object { $_.slug -eq 'beta' }).ingredients
    $c = @($out.recipes | Where-Object { $_.slug -eq 'gamma' }).ingredients
    Chk 'MUST FIRE  the unitless buy is carried across (alpha)' ((@($a | Where-Object { $_.item -eq 'Yellow Onion' }).buy) -eq '2.3 onions') (@($a | Where-Object { $_.item -eq 'Yellow Onion' }).buy)
    Chk 'MUST FIRE  the SECOND recipe with the same count is patched too, not skipped' ((@($b | Where-Object { $_.item -eq 'Yellow Onion' }).buy) -eq '2.3 onions') (@($b | Where-Object { $_.item -eq 'Yellow Onion' }).buy)
    Chk 'CLEAN TWIN a label that already agrees is untouched' ((@($a | Where-Object { $_.item -eq 'Pork Loin' }).buy) -eq '5.75 lb') (@($a | Where-Object { $_.item -eq 'Pork Loin' }).buy)
    $cCel = @($c | Where-Object { $_.item -eq 'Celery' }).buy
    $cJal = @($c | Where-Object { $_.item -eq 'Jalapeno' }).buy
    Chk 'CLEAN TWIN real drift is REPORTED, never rewritten (9 stalks vs 3.5 stalks)' (($cCel -eq '9 stalks') -and (($r.drift -join '|') -match 'gamma :: Celery')) ($cCel + ' / drift=' + ($r.drift -join '|'))
    Chk 'MUST FIRE  a unitless RANGE is carried across too (1-2 -> 3 jalapenos)' ($cJal -eq '3 jalapenos') ($cJal)
    $d = @($out.recipes | Where-Object { $_.slug -eq 'delta' }).ingredients
    Chk 'MUST FIRE  a PRETTY-PRINTED row is patched too (the shape-regex blind spot)' ((@($d).buy) -eq '1 leaf') (@($d).buy)
    Chk 'the file still parses and keeps all four rows' (@($out.recipes).Count -eq 4) ("rows=" + @($out.recipes).Count)
    Chk 'exactly four changes were made' ($r.changed -eq 4) ("changed=" + $r.changed)
    $r2 = Sync-RecipesDbBuy -Raw $r.text -SpecBuy $specBuy
    Chk 'idempotent - a second pass changes nothing' ($r2.changed -eq 0) ("changed=" + $r2.changed)

    # ---------------------------------------------------------------------------------------------
    # SECOND FROZEN FIXTURE - the cook-measure carry class (founding bug: 2026-08-04).
    # A SEPARATE fixture on purpose. The block above pins the unitless-count class and stays frozen
    # byte for byte; growing it to cover a second class would mean editing the founding bug's own
    # evidence every time a class is added, which is how a frozen fixture stops being frozen.
    #
    # The three MUST FIRE rows are real: the exact strings and gram figures off Brad's live specs on
    # 2026-08-04, one per shape the repair produces (a plain cup measure, a cup measure carrying a
    # pack-size tail, and a COUNTABLE that beats cups in the preference order).
    # The four CLEAN TWINS are the ways a row can look like this class and not be it. Each one is a
    # value this script must refuse to touch, and the last two are the dangerous ones: a spec that is
    # merely plausible, and a measure-vs-grams defect whose grams might be the wrong side.
    # ---------------------------------------------------------------------------------------------
    $densFx = @{ items = @{
        'Seasoned Black Beans'   = @{ can = 255; cup = 172 }
        'Marinara Sauce'         = @{ cup = 250; jar = 680 }
        'Reduced Fat Mozzarella' = @{ cup = 113; tbsp = 7; slice = 28 }
        'Diced Tomatoes'         = @{ can = 411; cup = 240 }
        'Soy Sauce'              = @{ cup = 255; tbsp = 16; tsp = 5.3 }
        'Olive Oil'              = @{ cup = 216; tbsp = 13.5 }
    } } | ConvertTo-Json -Depth 6 | ConvertFrom-Json     # round-trip so it is the same shape as db\densities.json
    $fx2 = @'
{"recipes":[
{"slug":"epsilon","name":"Epsilon","ingredients":[
{"item":"Seasoned Black Beans","grams":910,"buy":"2 cans","item_id":"black-beans"},
{"item":"Marinara Sauce","grams":1076,"buy":"2 jars (24 oz each)","item_id":"marinara-sauce"},
{"item":"Reduced Fat Mozzarella","grams":392,"buy":"2 bags (8 oz each)","item_id":"mozzarella"},
{"item":"Diced Tomatoes","grams":411,"buy":"1 can","item_id":"diced-tomatoes"},
{"item":"Soy Sauce","grams":120,"buy":"1 bottle","item_id":"soy-sauce"},
{"item":"Olive Oil","grams":42,"buy":"1 tbsp","item_id":"olive-oil"}]},
{"slug":"zeta","name":"Zeta","ingredients":[
{"item":"Seasoned Black Beans","grams":500,"buy":"2 cans","item_id":"black-beans"}]}
]}
'@
    $specBuy2 = @{
        'epsilon' = @{
            # MUST FIRE - db label proven false, spec label is Get-CookMeasure's own output
            'Seasoned Black Beans'   = [pscustomobject]@{ Buy = '5 1/4 cups';              Grams = 910;  Item = 'Seasoned Black Beans' }
            'Marinara Sauce'         = [pscustomobject]@{ Buy = '4 1/3 cups (24 oz each)'; Grams = 1076; Item = 'Marinara Sauce' }
            'Reduced Fat Mozzarella' = [pscustomobject]@{ Buy = '14 slices (8 oz each)';   Grams = 392;  Item = 'Reduced Fat Mozzarella' }
            # CLEAN TWIN - "1 can" of a 411 g can IS a true label, so the spec differing is a question
            'Diced Tomatoes'         = [pscustomobject]@{ Buy = '1 3/4 cups';              Grams = 411;  Item = 'Diced Tomatoes' }
            # CLEAN TWIN - true, but NOT what the repair writes from "1 bottle" (that is "1/2 cup"): a hand edit
            'Soy Sauce'              = [pscustomobject]@{ Buy = '1/3 cup';                 Grams = 120;  Item = 'Soy Sauce' }
            # CLEAN TWIN - a MEASURING unit disagreement: either the label or the grams is wrong and the
            # grams drive cost and macros, so this is the two-sided defect cook-measure-lib refuses on purpose
            'Olive Oil'              = [pscustomobject]@{ Buy = '3 tbsp';                  Grams = 42;   Item = 'Olive Oil' }
        }
        # CLEAN TWIN - identical label shape to the first MUST FIRE row, but the two sides disagree about
        # how much food there is, so nothing about the labels can be concluded
        'zeta' = @{ 'Seasoned Black Beans' = [pscustomobject]@{ Buy = '5 1/4 cups'; Grams = 910; Item = 'Seasoned Black Beans' } }
    }
    $r3 = Sync-RecipesDbBuy -Raw $fx2 -SpecBuy $specBuy2 -Dens $densFx.items
    $o3 = $r3.text | ConvertFrom-Json
    $e = @($o3.recipes | Where-Object { $_.slug -eq 'epsilon' }).ingredients
    $z = @($o3.recipes | Where-Object { $_.slug -eq 'zeta' }).ingredients
    function Buy2([object]$ings, [string]$n) { return [string](@($ings | Where-Object { $_.item -eq $n }).buy) }
    $dr3 = ($r3.drift -join ' || ')
    Chk 'MUST FIRE  a false PACKAGE noun is carried across (2 cans -> 5 1/4 cups)' ((Buy2 $e 'Seasoned Black Beans') -eq '5 1/4 cups') (Buy2 $e 'Seasoned Black Beans')
    Chk 'MUST FIRE  the pack-size tail survives the carry (2 jars (24 oz each) -> 4 1/3 cups (24 oz each))' ((Buy2 $e 'Marinara Sauce') -eq '4 1/3 cups (24 oz each)') (Buy2 $e 'Marinara Sauce')
    Chk 'MUST FIRE  a COUNTABLE replacement carries too (2 bags -> 14 slices)' ((Buy2 $e 'Reduced Fat Mozzarella') -eq '14 slices (8 oz each)') (Buy2 $e 'Reduced Fat Mozzarella')
    Chk 'CLEAN TWIN a package noun that EQUALS the grams is a true label - reported, not carried' (((Buy2 $e 'Diced Tomatoes') -eq '1 can') -and ($dr3 -match 'not provably false')) ((Buy2 $e 'Diced Tomatoes') + ' / ' + $dr3)
    Chk 'CLEAN TWIN a plausible spec that is NOT the repair output is refused as hand-edited' (((Buy2 $e 'Soy Sauce') -eq '1 bottle') -and ($dr3 -match 'hand-edited')) ((Buy2 $e 'Soy Sauce') + ' / ' + $dr3)
    Chk 'CLEAN TWIN a MEASURING-unit disagreement is never laundered (1 tbsp vs 3 tbsp, 42 g)' ((Buy2 $e 'Olive Oil') -eq '1 tbsp') (Buy2 $e 'Olive Oil')
    Chk 'CLEAN TWIN disagreeing GRAMS block the carry even on an identical label shape' (((Buy2 $z 'Seasoned Black Beans') -eq '2 cans') -and ($dr3 -match 'grams disagree')) ((Buy2 $z 'Seasoned Black Beans') + ' / ' + $dr3)
    Chk 'exactly three cook-measure changes, and every one is named as that class' (($r3.changed -eq 3) -and (@($r3.changes | Where-Object { $_.Class -eq 'cook-measure' }).Count -eq 3)) ("changed=" + $r3.changed)
    Chk 'the four refusals are all reported as drift' ($r3.drift.Count -eq 4) ("drift=" + $r3.drift.Count)
    $r4 = Sync-RecipesDbBuy -Raw $r3.text -SpecBuy $specBuy2 -Dens $densFx.items
    Chk 'idempotent - a second cook-measure pass changes nothing' ($r4.changed -eq 0) ("changed=" + $r4.changed)
    # WITHOUT densities the class cannot be evaluated at all, and must not degrade into a blind carry.
    $r5 = Sync-RecipesDbBuy -Raw $fx2 -SpecBuy $specBuy2
    Chk 'CLEAN TWIN no densities in hand means NOTHING is carried, not everything' ($r5.changed -eq 0) ("changed=" + $r5.changed)

    # ---------------------------------------------------------------------------------------------
    # THIRD FROZEN FIXTURE - the scaled-note carry class (founding bug: 2026-08-04).
    # Its own fixture for the same reason the second one is separate: the blocks above stay frozen on
    # the evidence of the bugs that created them.
    #
    # The rows are real - the exact strings off Brad's two live specs before repair-scaled-notes.ps1 ran.
    # DO NOT "fix" the singular "Green Bell Pepper" below to match live data. The catalog was renamed to
    # "Green Bell Peppers" on 2026-08-04 (see the ORPHAN NAME note in repair-scaled-notes.ps1), but the
    # singular IS the founding bug here: it is the name that had no densities entry, which is the whole
    # point of the MUST FIRE case it feeds. Renaming it would leave the assertion passing while testing
    # nothing - the fixture is frozen on the evidence, not on the tree.
    # The MUST FIRE cases are the two shapes: a bare count and a count that also changes unit. The CLEAN
    # TWINS are the four ways a row can look like this class and not be it, and the last two are the ones
    # that matter, because they are how an automated sync would start ratifying edits nobody reviewed.
    # ---------------------------------------------------------------------------------------------
    $fx3 = @'
{"recipes":[
{"slug":"salsa","name":"Salsa","ingredients":[
{"item":"Yellow Onion","grams":330,"buy":"1 (scaled ~3)","item_id":"onions"},
{"item":"Green Bell Pepper","grams":350,"buy":"1 (scaled ~3)","item_id":"green-bell-pepper"}]},
{"slug":"bol","name":"Bol","ingredients":[
{"item":"Garlic","grams":25,"buy":"1 clove (scaled ~4)","item_id":"garlic"},
{"item":"Celery","grams":140,"buy":"1 rib (scaled ~3)","item_id":"celery"},
{"item":"Carrots","grams":200,"buy":"1 (scaled ~3)","item_id":"carrots"}]}
]}
'@
    $specBuy3 = @{
        'salsa' = @{
            'Yellow Onion'      = [pscustomobject]@{ Buy = '3 onions';  Grams = 330; Item = 'Yellow Onion' }
            'Green Bell Pepper' = [pscustomobject]@{ Buy = '3 peppers'; Grams = 350; Item = 'Green Bell Pepper' }
        }
        'bol' = @{
            'Garlic'  = [pscustomobject]@{ Buy = '3 tbsp';      Grams = 25;  Item = 'Garlic' }
            'Celery'  = [pscustomobject]@{ Buy = '2.5 stalks';  Grams = 140; Item = 'Celery' }
            'Carrots' = [pscustomobject]@{ Buy = '3.3 carrots'; Grams = 200; Item = 'Carrots' }
        }
    }
    $carry3 = @{
        'salsa|Yellow Onion'      = [pscustomobject]@{ Old = '1 (scaled ~3)';       New = '3 onions' }
        'salsa|Green Bell Pepper' = [pscustomobject]@{ Old = '1 (scaled ~3)';       New = '3 peppers' }
        'bol|Garlic'              = [pscustomobject]@{ Old = '1 clove (scaled ~4)'; New = '3 tbsp' }
        # Celery is deliberately ABSENT from the manifest, and bol|Carrots is present but STALE.
        'bol|Carrots'             = [pscustomobject]@{ Old = '1 (scaled ~3)';       New = '3 carrots' }
    }
    $r6 = Sync-RecipesDbBuy -Raw $fx3 -SpecBuy $specBuy3 -Dens $densFx.items -Carry $carry3
    $o6 = $r6.text | ConvertFrom-Json
    $sv = @($o6.recipes | Where-Object { $_.slug -eq 'salsa' }).ingredients
    $bo = @($o6.recipes | Where-Object { $_.slug -eq 'bol' }).ingredients
    $dr6 = ($r6.drift -join ' || ')
    Chk 'MUST FIRE  a manifested authoring note is carried across (1 (scaled ~3) -> 3 onions)' ((Buy2 $sv 'Yellow Onion') -eq '3 onions') (Buy2 $sv 'Yellow Onion')
    Chk 'MUST FIRE  it fires for an item with no densities entry at all (Green Bell Pepper)' ((Buy2 $sv 'Green Bell Pepper') -eq '3 peppers') (Buy2 $sv 'Green Bell Pepper')
    Chk 'MUST FIRE  a note whose unit also changes carries (1 clove -> 3 tbsp)' ((Buy2 $bo 'Garlic') -eq '3 tbsp') (Buy2 $bo 'Garlic')
    Chk 'CLEAN TWIN a note NO repair run claims is refused, not carried' (((Buy2 $bo 'Celery') -eq '1 rib (scaled ~3)') -and ($dr6 -match 'no repair run claims')) ((Buy2 $bo 'Celery') + ' / ' + $dr6)
    Chk 'CLEAN TWIN a spec that disagrees with the manifest reads as a later hand edit' (((Buy2 $bo 'Carrots') -eq '1 (scaled ~3)') -and ($dr6 -match 'looks hand-edited since')) ((Buy2 $bo 'Carrots') + ' / ' + $dr6)
    Chk 'exactly three scaled-note changes, and every one is named as that class' (($r6.changed -eq 3) -and (@($r6.changes | Where-Object { $_.Class -eq 'scaled-note' }).Count -eq 3)) ("changed=" + $r6.changed)
    $r7 = Sync-RecipesDbBuy -Raw $r6.text -SpecBuy $specBuy3 -Dens $densFx.items -Carry $carry3
    Chk 'idempotent - a second scaled-note pass changes nothing' ($r7.changed -eq 0) ("changed=" + $r7.changed)

    # ---------------------------------------------------------------------------------------------
    # FIFTH FROZEN FIXTURE - the measure-vs-grams carry class (founding bug: 2026-08-04).
    # Real rows, taken off the live specs before repair-measure-vs-grams.ps1 ran.
    #
    # WHAT MAKES THIS CLASS DIFFERENT, and what the fixture has to prove: every label below is
    # WELL-FORMED. "1/4 tsp" names a unit, states one quantity, carries no authoring note and reads like
    # any correct line on the card - it is simply not the amount this recipe uses. So there is nothing in
    # the string for a guard to catch, and the CLEAN TWINS here are the important half: an identical-
    # looking label that no repair claims must NOT be carried, or this class becomes a blind overwrite of
    # reader-facing text and every argument for the other three collapses with it.
    #
    # cheeseburger|Salt is the row that proves the point hardest: it looks exactly like slug 'gyro's
    # Black Pepper row, and it is absent from the manifest because that recipe's cited source is a dead
    # link (HTTP 404) and nobody could establish which side was wrong. It must come through untouched.
    # ---------------------------------------------------------------------------------------------
    $fx5 = @'
{"recipes":[
{"slug":"gyro","name":"Gyro","ingredients":[
{"item":"Black Pepper","grams":4,"buy":"1/2 tsp","item_id":"black-pepper"},
{"item":"Rice","grams":1201,"buy":"1 lb","item_id":"rice"},
{"item":"Salt","grams":20,"buy":"1 tsp meat + 1/2 tsp tzatziki","item_id":"salt"}]},
{"slug":"cheeseburger","name":"Cheeseburger","ingredients":[
{"item":"Salt","grams":18,"buy":"1 tsp","item_id":"salt"},
{"item":"Olive Oil","grams":45,"buy":"1 Tbsp","item_id":"olive-oil"}]}
]}
'@
    $specBuy5 = @{
        'gyro' = @{
            'Black Pepper' = [pscustomobject]@{ Buy = '1.75 tsp';     Grams = 4;    Item = 'Black Pepper' }
            'Rice'         = [pscustomobject]@{ Buy = '6.5 cups dry'; Grams = 1201; Item = 'Rice' }
            # the spec REFUSED this one (its tail carries a second quantity), so spec and db still agree
            'Salt'         = [pscustomobject]@{ Buy = '1 tsp meat + 1/2 tsp tzatziki'; Grams = 20; Item = 'Salt' }
        }
        'cheeseburger' = @{
            # the spec was hand-edited to a true label, but no repair run claims either row
            'Salt'      = [pscustomobject]@{ Buy = '1 tbsp';     Grams = 18; Item = 'Salt' }
            'Olive Oil' = [pscustomobject]@{ Buy = '3.25 tbsp';  Grams = 45; Item = 'Olive Oil' }
        }
    }
    $mcarry5 = @{
        'gyro|Black Pepper' = [pscustomobject]@{ Old = '1/2 tsp'; New = '1.75 tsp' }
        'gyro|Rice'         = [pscustomobject]@{ Old = '1 lb';    New = '6.5 cups dry' }
        # cheeseburger|Salt and |Olive Oil are deliberately ABSENT - source was a dead link, nobody decided
    }
    $r11 = Sync-RecipesDbBuy -Raw $fx5 -SpecBuy $specBuy5 -Dens $densFx.items -MeasureCarry $mcarry5
    $o11 = $r11.text | ConvertFrom-Json
    $gy = @($o11.recipes | Where-Object { $_.slug -eq 'gyro' }).ingredients
    $cb = @($o11.recipes | Where-Object { $_.slug -eq 'cheeseburger' }).ingredients
    $dr11 = ($r11.drift -join ' || ')
    Chk 'MUST FIRE  a manifested measure label is carried (1/2 tsp -> 1.75 tsp)' ((Buy2 $gy 'Black Pepper') -eq '1.75 tsp') (Buy2 $gy 'Black Pepper')
    Chk 'MUST FIRE  the filler "1 lb" carries too (-> 6.5 cups dry)' ((Buy2 $gy 'Rice') -eq '6.5 cups dry') (Buy2 $gy 'Rice')
    Chk 'CLEAN TWIN an identical-looking label no repair claims is NOT carried' ((Buy2 $cb 'Salt') -eq '1 tsp') (Buy2 $cb 'Salt')
    Chk 'CLEAN TWIN nor is a true-but-unclaimed spec label ratified' ((Buy2 $cb 'Olive Oil') -eq '1 Tbsp') (Buy2 $cb 'Olive Oil')
    Chk 'CLEAN TWIN a row the repair itself refused leaves db and spec already in step' ((Buy2 $gy 'Salt') -eq '1 tsp meat + 1/2 tsp tzatziki') (Buy2 $gy 'Salt')
    Chk 'exactly two measure-vs-grams changes, each named as that class' (($r11.changed -eq 2) -and (@($r11.changes | Where-Object { $_.Class -eq 'measure-vs-grams' }).Count -eq 2)) ("changed=" + $r11.changed)
    $r12 = Sync-RecipesDbBuy -Raw $r11.text -SpecBuy $specBuy5 -Dens $densFx.items -MeasureCarry $mcarry5
    Chk 'idempotent - a second measure-vs-grams pass changes nothing' ($r12.changed -eq 0) ("changed=" + $r12.changed)
    # NO MANIFEST is the normal state of the tree. This class has no string shape to fall back on, so an
    # absent manifest must mean it carries NOTHING rather than degrading into a blind label overwrite.
    $r13 = Sync-RecipesDbBuy -Raw $fx5 -SpecBuy $specBuy5 -Dens $densFx.items
    Chk 'CLEAN TWIN with no manifest in hand this class carries NOTHING' ($r13.changed -eq 0) ("changed=" + $r13.changed)
    # A STALE manifest must not fire either - the db row moved on since the repair ran.
    $stale5 = @{ 'gyro|Black Pepper' = [pscustomobject]@{ Old = '1/4 tsp'; New = '1.75 tsp' } }
    $r14 = Sync-RecipesDbBuy -Raw $fx5 -SpecBuy $specBuy5 -Dens $densFx.items -MeasureCarry $stale5
    Chk 'CLEAN TWIN a manifest that no longer matches the db row is refused' (($r14.changed -eq 0) -and (($r14.drift -join '|') -match 'changed since the repair ran')) ("changed=" + $r14.changed + ' / ' + ($r14.drift -join '|'))
    # NO MANIFEST is the normal state of the tree, and it must carry NOTHING rather than fall back on
    # the script's own judgement. This is the guard that keeps the class from becoming a blind sync.
    $r8 = Sync-RecipesDbBuy -Raw $fx3 -SpecBuy $specBuy3 -Dens $densFx.items
    Chk 'CLEAN TWIN with no manifest in hand the class carries NOTHING' (($r8.changed -eq 0) -and (($r8.drift -join '|') -match 'no carry manifest is present')) ("changed=" + $r8.changed + ' / ' + ($r8.drift -join '|'))
    # And an authoring note must never reach a reader through the planner by another class's back door.
    Chk 'no authoring note survives in anything this class carried' (($r6.changes | Where-Object { $_.New -match '\(scaled ~' }).Count -eq 0) 'a note was carried across'

    # ---------------------------------------------------------------------------------------------
    # FOURTH FROZEN FIXTURE - the range-buy carry class (founding bug: 2026-08-04).
    # The MUST FIRE rows are real, off Brad's live specs: the garlic range that started it, and the
    # jerk-pork broth whose replacement is HAND-ADJUDICATED (it drops a note restating the ingredient),
    # which is the row that proves a manifest carries what a repair DID rather than what it could derive.
    # The clean twins are the two ways a range row can look carryable and not be, plus the one that
    # matters most: a range must not be able to ride in on the cook-measure class instead, because
    # Test-CmLabelTrue reads no unit past a dash and would wave it through as "not provably false".
    # ---------------------------------------------------------------------------------------------
    $fx4 = @'
{"recipes":[
{"slug":"stir","name":"Stir","ingredients":[
{"item":"Garlic","grams":42,"buy":"2-3 cloves, minced","item_id":"garlic"},
{"item":"Chicken Broth","grams":240,"buy":"1/2-1 cup low-sodium vegetable or chicken broth","item_id":"chicken-broth"},
{"item":"Sriracha","grams":25,"buy":"1-2 tsp","item_id":"sriracha"},
{"item":"Jalapeno","grams":35,"buy":"3-4 dry chiles or 1.5 Tbsp chile powder","item_id":"jalapenos"},
{"item":"Tortillas","grams":340,"buy":"12-oz bag","item_id":"tortillas"}]}
]}
'@
    $specBuy4 = @{
        'stir' = @{
            'Garlic'        = [pscustomobject]@{ Buy = '8 cloves, minced'; Grams = 42;  Item = 'Garlic' }
            'Chicken Broth' = [pscustomobject]@{ Buy = '1 cup';            Grams = 240; Item = 'Chicken Broth' }
            # CLEAN TWIN - a real range in the db, but no manifest row claims it
            'Sriracha'      = [pscustomobject]@{ Buy = '5 tsp';            Grams = 25;  Item = 'Sriracha' }
            # CLEAN TWIN - manifested, but the spec has moved since the repair wrote it
            'Jalapeno'      = [pscustomobject]@{ Buy = '3 jalapenos';      Grams = 35;  Item = 'Jalapeno' }
            # CLEAN TWIN - a hyphen that is not a range must not be pulled into this class at all
            'Tortillas'     = [pscustomobject]@{ Buy = '1 bag';            Grams = 340; Item = 'Tortillas' }
        }
    }
    $rcarry4 = @{
        'stir|Garlic'        = [pscustomobject]@{ Old = '2-3 cloves, minced'; New = '8 cloves, minced' }
        'stir|Chicken Broth' = [pscustomobject]@{ Old = '1/2-1 cup low-sodium vegetable or chicken broth'; New = '1 cup' }
        'stir|Jalapeno'      = [pscustomobject]@{ Old = '3-4 dry chiles or 1.5 Tbsp chile powder'; New = '2 1/2 jalapenos' }
    }
    $r9 = Sync-RecipesDbBuy -Raw $fx4 -SpecBuy $specBuy4 -Dens $densFx.items -RangeCarry $rcarry4
    $st = @(($r9.text | ConvertFrom-Json).recipes | Where-Object { $_.slug -eq 'stir' }).ingredients
    $dr9 = ($r9.drift -join ' || ')
    Chk 'MUST FIRE  a manifested range is carried across (2-3 cloves -> 8 cloves)' ((Buy2 $st 'Garlic') -eq '8 cloves, minced') (Buy2 $st 'Garlic')
    Chk 'MUST FIRE  a HAND-ADJUDICATED replacement carries on the manifest alone (broth -> 1 cup)' ((Buy2 $st 'Chicken Broth') -eq '1 cup') (Buy2 $st 'Chicken Broth')
    Chk 'CLEAN TWIN a range no repair run claims is refused, not carried' (((Buy2 $st 'Sriracha') -eq '1-2 tsp') -and ($dr9 -match 'no repair run claims')) ((Buy2 $st 'Sriracha') + ' / ' + $dr9)
    Chk 'CLEAN TWIN a spec that disagrees with the manifest reads as a later hand edit' (((Buy2 $st 'Jalapeno') -match '^3-4 dry chiles') -and ($dr9 -match 'looks hand-edited since')) ((Buy2 $st 'Jalapeno') + ' / ' + $dr9)
    Chk 'CLEAN TWIN "12-oz bag" is not a range and never enters this class' (((Buy2 $st 'Tortillas') -eq '12-oz bag') -and ($dr9 -notmatch 'Tortillas.*range')) ((Buy2 $st 'Tortillas') + ' / ' + $dr9)
    Chk 'exactly two range-buy changes, and every one is named as that class' (($r9.changed -eq 2) -and (@($r9.changes | Where-Object { $_.Class -eq 'range-buy' }).Count -eq 2)) ("changed=" + $r9.changed)
    $r10 = Sync-RecipesDbBuy -Raw $r9.text -SpecBuy $specBuy4 -Dens $densFx.items -RangeCarry $rcarry4
    Chk 'idempotent - a second range-buy pass changes nothing' ($r10.changed -eq 0) ("changed=" + $r10.changed)
    # THE GUARD THAT KEEPS THE CLASS HONEST: no manifest carries nothing, and in particular a range must
    # not fall through to the cook-measure class, which cannot read a unit past a dash and would pass it.
    $r11 = Sync-RecipesDbBuy -Raw $fx4 -SpecBuy $specBuy4 -Dens $densFx.items
    Chk 'CLEAN TWIN with no manifest in hand the class carries NOTHING' (($r11.changed -eq 0) -and (($r11.drift -join '|') -match 'no carry manifest is present')) ("changed=" + $r11.changed + ' / ' + ($r11.drift -join '|'))
    Chk 'no range survives in anything this class carried' ((@($r9.changes | Where-Object { Test-RangeBuy -Buy ([string]$_.New) }).Count) -eq 0) 'a range was carried across'

    if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$dbPath = Join-Path $mp 'recipes-db.json'
$densPath = Join-Path $mp 'db\densities.json'
$carryPath = Join-Path $mp 'out\scaled-note-carry.json'
$specBuy = Get-SpecBuyMap (Join-Path $mp 'db\recipes')
# the scaled-note manifest, keyed slug|item. Absent is the normal state - it only exists in the window
# between repair-scaled-notes.ps1 -Apply and this sync - and absent means that class carries NOTHING
# rather than falling back on its own judgement.
$carry = $null
if (Test-Path $carryPath) {
    $carry = @{}
    foreach ($c in @((Get-Content $carryPath -Raw | ConvertFrom-Json))) {
        if (-not $c -or -not $c.slug) { continue }
        $carry[([string]$c.slug + '|' + [string]$c.item)] = [pscustomobject]@{ Old = [string]$c.old; New = [string]$c.new }
    }
    Write-Output ("  scaled-note carry manifest: {0} row(s) from out\scaled-note-carry.json" -f $carry.Count)
}
# the range-buy manifest, same arrangement and for the same reason - absent means that class carries
# NOTHING, which is the normal state outside the window between repair-range-buy.ps1 -Apply and this sync.
$rangeCarryPath = Join-Path $mp 'out\range-buy-carry.json'
$rangeCarry = $null
if (Test-Path $rangeCarryPath) {
    $rangeCarry = @{}
    foreach ($c in @((Get-Content $rangeCarryPath -Raw | ConvertFrom-Json))) {
        if (-not $c -or -not $c.slug) { continue }
        $rangeCarry[([string]$c.slug + '|' + [string]$c.item)] = [pscustomobject]@{ Old = [string]$c.old; New = [string]$c.new }
    }
    Write-Output ("  range-buy carry manifest: {0} row(s) from out\range-buy-carry.json" -f $rangeCarry.Count)
}
# the measure-vs-grams manifest, same arrangement again. This one matters more than the other two,
# because its class has no shape to fall back on: with no manifest the 292 rows it covers are simply
# invisible to every guard here, so an absent file means that class carries NOTHING and says so.
$measureCarryPath = Join-Path $mp 'out\measure-vs-grams-carry.json'
$measureCarry = $null
if (Test-Path $measureCarryPath) {
    $measureCarry = @{}
    foreach ($c in @((Get-Content $measureCarryPath -Raw | ConvertFrom-Json))) {
        if (-not $c -or -not $c.slug) { continue }
        $measureCarry[([string]$c.slug + '|' + [string]$c.item)] = [pscustomobject]@{ Old = [string]$c.old; New = [string]$c.new }
    }
    Write-Output ("  measure-vs-grams carry manifest: {0} row(s) from out\measure-vs-grams-carry.json" -f $measureCarry.Count)
}
# The absurd-unit promotion (repair-absurd-units.ps1) rides the SAME channel, and for the same reason:
# "26 tbsp" is not provably false, it is merely unusable, so Get-BuyCarryClass can never derive the edit
# and the manifest is the entire trigger. It is a separate FILE rather than a separate parameter because
# the carry rule it needs is identical - match old byte for byte, then take new - and a fourth near-copy
# of that rule is the two-copies-of-the-same-math failure this lib exists to avoid.
$absurdCarryPath = Join-Path $mp 'out\absurd-unit-carry.json'
if (Test-Path $absurdCarryPath) {
    if (-not $measureCarry) { $measureCarry = @{} }
    $n = 0
    foreach ($c in @((Get-Content $absurdCarryPath -Raw | ConvertFrom-Json))) {
        if (-not $c -or -not $c.slug) { continue }
        $measureCarry[([string]$c.slug + '|' + [string]$c.item)] = [pscustomobject]@{ Old = [string]$c.old; New = [string]$c.new }
        $n++
    }
    Write-Output ("  absurd-unit carry manifest: {0} row(s) from out\absurd-unit-carry.json" -f $n)
}
# The unmeasurable-quantity repair (repair-unmeasurable-qty.ps1) is the absurd-unit class from the other
# end - a real amount named in a unit too LARGE to show it, "Bay Leaves: 0.07 oz" - and it rides the same
# channel for the same reason: 2 g really does weigh 0.07 oz, so the db label is not provably FALSE and
# Get-BuyCarryClass will never derive the edit on its own. Fifth file on one rule, still not a fifth copy
# of the rule.
$zeroCarryPath = Join-Path $mp 'out\unmeasurable-qty-carry.json'
if (Test-Path $zeroCarryPath) {
    if (-not $measureCarry) { $measureCarry = @{} }
    $n = 0
    foreach ($c in @((Get-Content $zeroCarryPath -Raw | ConvertFrom-Json))) {
        if (-not $c -or -not $c.slug) { continue }
        $measureCarry[([string]$c.slug + '|' + [string]$c.item)] = [pscustomobject]@{ Old = [string]$c.old; New = [string]$c.new }
        $n++
    }
    Write-Output ("  unmeasurable-qty carry manifest: {0} row(s) from out\unmeasurable-qty-carry.json" -f $n)
}
# densities are what the cook-measure class weighs its evidence with. Missing them does not silently
# downgrade the run to the unitless class alone - say so, because a clean "0 labels" line off a run that
# could not evaluate the class reads exactly like a clean "0 labels" off a run that found nothing.
$dens = $null
if (Test-Path $densPath) { $dens = (Get-Content $densPath -Raw | ConvertFrom-Json).items }
else { Write-Output "  WARNING: no db\densities.json - the cook-measure class cannot be evaluated this run" }
$raw = [System.IO.File]::ReadAllText($dbPath)
$res = Sync-RecipesDbBuy -Raw $raw -SpecBuy $specBuy -Dens $dens -Carry $carry -RangeCarry $rangeCarry -MeasureCarry $measureCarry
Write-Output ("recipes-db buy sync: {0} label(s){1}" -f $res.changed, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))
foreach ($g in ($res.changes | Group-Object Class | Sort-Object Name)) { Write-Output ("    class {0,-16} {1}" -f $g.Name, $g.Count) }
foreach ($c in ($res.changes | Select-Object -First 10)) { Write-Output ("    {0,-40} {1,-22} '{2}' -> '{3}'" -f $c.Slug, $c.Item, $c.Old, $c.New) }
if ($res.changed -gt 10) { Write-Output ("    ... and {0} more" -f ($res.changed - 10)) }
if ($res.drift.Count) {
    Write-Output ("  DRIFT this script did not cause and will not rewrite ({0}):" -f $res.drift.Count)
    foreach ($d in ($res.drift | Select-Object -First 15)) { Write-Output ('    ' + $d) }
    if ($res.drift.Count -gt 15) { Write-Output ("    ... and {0} more" -f ($res.drift.Count - 15)) }
}
if ($Apply -and $res.changed -gt 0) {
    Copy-Item $dbPath ($dbPath + '.bak-buysync') -Force
    $null = $res.text | ConvertFrom-Json          # parse-verify before writing
    [System.IO.File]::WriteAllText($dbPath, $res.text)
    Write-Output ("  written (backup -> recipes-db.json.bak-buysync)")
}
exit 0
