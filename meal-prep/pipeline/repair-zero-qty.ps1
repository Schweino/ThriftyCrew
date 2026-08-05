<#
  repair-zero-qty.ps1 - a label that asks the reader for NOTHING gets the unit it should have carried.

  THE DEFECT. 15 labels across the 513 specs state a quantity of zero in a unit the ingredient is too
  small to register in:

      arroz-con-pollo-bowls                 Bay Leaves       "0 oz"    (3 g)
      pastitsio                             Ground Cloves    "0 oz"    (1 g)
      hong-kongstyle-baked-pork-chop-rice   Chicken Broth    "0 lb"    (42 g)
      turkey-sausage-and-cheesy-grits-bowl  Salt             "0 tbsp"  (2 g)
      ... and 11 more, all spices and one broth

  A shopper reading "Bay Leaves: 0 oz" is being told to buy none of an ingredient the method then asks
  them to cook with. It is the ABSURD-UNIT defect from the other end: that one names a real quantity in a
  unit too SMALL to count in (105 tbsp of cilantro), this one names a real quantity in a unit too LARGE
  to show it (3 g of bay leaves in ounces). Both print a number no kitchen can act on.

  WHY IT IS A LEGACY CLASS AND NOT A LIVE BUG. friendly-amt-lib already refuses to emit these. Get-FaFrac
  drops to two decimals below a quarter unit precisely "so a small amount never prints '0'", and its
  comment names the founding case - r100 shipped "Bay Leaves ... 0 oz". These 15 are labels written
  before that guard existed and never re-derived since. So the repair is not a new rule: it is running
  the estate's own current label generator over rows the old one wrote.

  NOTHING IS ADJUDICATED, which is the line this repair will not cross. The grams are untouched, the cost
  is untouched, the quantity is untouched; only the unit the reader counts in changes, and the new unit
  comes from densities.json, which is authored data. That is the same distinction repair-absurd-units
  draws against the laundering cook-measure-lib refuses.

  AND IT REFUSES THE ROWS IT CANNOT HONESTLY FIX. A re-derived label has to be usable, not merely
  non-zero. chicken-biryani-rice-bowls carries Milk at 1 g, which re-derives to "0.07 tbsp" - that clears
  the guard's regex and stays exactly as unmeasurable as the zero it replaced. Clearing a gate with a
  label nobody can act on is the failure repair-absurd-units was written to avoid, so this script leaves
  that row alone and REPORTS it. 1 g of milk across 14 servings is a question about the grams, and grams
  are not this lane's to move.

  Usage: repair-zero-qty.ps1 [-Apply] [-SelfTest]
         Read-only by default: prints what it would change and writes nothing.
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path $mp 'lib\json-db-io.ps1')
. (Join-Path $here 'buy-label-lib.ps1')
. (Join-Path $here 'cook-measure-lib.ps1')
. (Join-Path $here 'friendly-amt-lib.ps1')

# The units audit-spec-contradictions' ZERO-QTY regex looks at. Kept in step with the sweep by the
# self-test below, the same way repair-absurd-units pins its threshold.
$script:ZeroUnits = @('lb','lbs','oz','cup','cups','tbsp','tsp')
# A re-derived label must reach a quarter of its unit to count as usable. Below that the reader is being
# handed another decimal they cannot measure - see the milk row in the header.
$script:UsableFloor = 0.25

function Test-ZeroQty {
    <# True when a buy label LEADS with a zero quantity in a measurable unit. #>
    param([string]$Buy)
    if (-not $Buy) { return $false }
    $u = Get-CmUnit $Buy
    if (-not $u -or ($script:ZeroUnits -notcontains $u)) { return $false }
    $q = Get-CmQty $Buy
    if ($null -eq $q) { return $false }
    return ($q -eq 0)
}

function Test-UsableLabel {
    <# A label is usable if it is a COUNT ("5 leaves") or reaches a quarter of its stated unit. #>
    param([string]$Label)
    if (-not $Label) { return $false }
    $q = Get-CmQty $Label
    if ($null -eq $q) { return $false }
    if ($q -le 0) { return $false }
    $u = Get-CmUnit $Label
    if (-not $u) { return $true }                       # a count: "5 leaves", "2 cartons"
    return ($q -ge $script:UsableFloor)
}

function Resolve-ZeroQty {
    <# Re-derive the label from the grams through the estate's own generator. $null when the result
       would still be unusable, so the caller reports the row instead of pretending it is fixed. #>
    param([string]$Item, [double]$Grams, [string]$Buy)
    if ($Grams -le 0) { return $null }
    $new = $null
    try { $new = Get-FriendlyAmt $Item $Grams } catch { return $null }   # no each-noun: refuse, do not guess
    if (-not $new -or $new -eq $Buy) { return $null }
    if (-not (Test-UsableLabel $new)) { return $null }
    $tail = Get-CmTail $Buy
    if ($tail) { return (Join-CmTail $new $tail) }
    return $new
}

function Repair-SpecZeroQty {
    <# Returns @{ changed; text; notes; edits } for ONE spec. Pure text in, text out. #>
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)]$Spec
    )
    $ing  = @($Spec.scaler.ing)
    $disp = @($Spec.ingredients_display)
    if ($ing.Count -ne $disp.Count) { throw ("parallel arrays disagree: scaler.ing $($ing.Count) vs ingredients_display $($disp.Count)") }

    $edits = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $ing.Count; $i++) {
        $buy = [string]$ing[$i].buy
        if (-not (Test-ZeroQty -Buy $buy)) { continue }
        $item = [string]$ing[$i].item
        $g = if ($ing[$i].PSObject.Properties.Name -contains 'grams' -and $ing[$i].grams) { [double]$ing[$i].grams } else { 0 }
        $new = Resolve-ZeroQty -Item $item -Grams $g -Buy $buy
        if (-not $new) {
            $notes.Add("'$item' buy '$buy' ($([int]$g) g): no usable unit exists for this amount - LEFT ALONE, the grams are the question")
            continue
        }
        $edits.Add([pscustomobject]@{ Index = $i; Item = $item; Old = $buy; New = $new; Grams = [int]$g })
    }
    if ($edits.Count -eq 0) { return @{ changed = 0; text = $Raw; notes = @($notes.ToArray()); edits = @() } }

    # -IncludeHead: head.recipeIngredient is derived from the card (invariant 9), so the JSON-LD would
    # otherwise keep serving "0 oz Bay Leaves" to Google after the page stopped saying it.
    $sp = Invoke-BuyLabelSplice -Raw $Raw -Spec $Spec -Edits @($edits.ToArray()) -IncludeHead
    foreach ($n in $sp.notes) { $notes.Add($n) }
    return @{ changed = $edits.Count; text = $sp.text; notes = @($notes.ToArray()); edits = @($edits.ToArray()) }
}

# ---------------------------------------------------------------- self-test

if ($SelfTest) {
    $fail = 0
    function Check($name, $got, $want) {
        if ("$got" -ne "$want") { Write-Output "  FAIL $name : got '$got' want '$want'"; $script:fail++ }
        else { Write-Output "  ok   $name" }
    }
    Write-Output 'repair-zero-qty self-test'
    Initialize-FriendlyAmt -Root $mp

    # the predicate
    Check 'flags 0 oz'            (Test-ZeroQty -Buy '0 oz')        $true
    Check 'flags 0 tbsp'          (Test-ZeroQty -Buy '0 tbsp')      $true
    Check 'flags 0 lb'            (Test-ZeroQty -Buy '0 lb')        $true
    Check 'leaves 0.25 tsp alone' (Test-ZeroQty -Buy '0.25 tsp')    $false
    Check 'leaves 1 oz alone'     (Test-ZeroQty -Buy '1 oz')        $false
    Check 'leaves a count alone'  (Test-ZeroQty -Buy '0 onions')    $false
    Check 'leaves empty alone'    (Test-ZeroQty -Buy '')            $false

    # usability, the rule that stops this becoming a guard-clearing exercise
    Check 'usable 1 tsp'          (Test-UsableLabel '1 tsp')        $true
    Check 'usable 0.25 cups'      (Test-UsableLabel '0.25 cups')    $true
    Check 'usable a count'        (Test-UsableLabel '5 leaves')     $true
    Check 'NOT usable 0.07 tbsp'  (Test-UsableLabel '0.07 tbsp')    $false
    Check 'NOT usable 0.11 oz'    (Test-UsableLabel '0.11 oz')      $false
    Check 'NOT usable 0 oz'       (Test-UsableLabel '0 oz')         $false

    # the conversion, through the real densities
    Check 'cloves 2 g -> tsp'     (Resolve-ZeroQty -Item 'Ground Cloves' -Grams 2 -Buy '0 oz')   '1 tsp'
    Check 'bay leaves 3 g -> count' (Resolve-ZeroQty -Item 'Bay Leaves' -Grams 3 -Buy '0 oz')    '5 leaves'
    Check 'broth 42 g -> cups'    (Resolve-ZeroQty -Item 'Chicken Broth' -Grams 42 -Buy '0 lb')  '0.25 cups'
    # MUST REFUSE: 1 g of milk has no usable unit; the row is a grams question, not a label question
    Check 'REFUSES milk 1 g'      ($null -eq (Resolve-ZeroQty -Item 'Milk' -Grams 1 -Buy '0 tbsp')) $true

    # THE MUST-FIRE FIXTURE: a zero label, a refusable one, and a clean twin that must not move.
    $fixture = @'
{
  "slug": "fixture-zeroqty",
  "ingredients_display": [
    "<strong>Bay Leaves (Great Value):</strong> 0 oz (3 g)",
    "<strong>Milk (Fairlife):</strong> 0 tbsp (1 g)",
    "<strong>Olive Oil:</strong> 3 tbsp (42 g)"
  ],
  "scaler": { "ing": [
    { "item": "Bay Leaves", "grams": 3, "buy": "0 oz" },
    { "item": "Milk", "grams": 1, "buy": "0 tbsp" },
    { "item": "Olive Oil", "grams": 42, "buy": "3 tbsp" }
  ] }
}
'@
    $fspec = $fixture | ConvertFrom-Json
    $r = Repair-SpecZeroQty -Raw $fixture -Spec $fspec
    Check 'fixture: exactly one edit'      $r.changed 1
    Check 'fixture: the zero one moved'    ($r.edits[0].New) '5 leaves'
    Check 'fixture: display rewritten'     ($r.text -match '5 leaves \(3 g\)') $true
    Check 'fixture: milk left alone'       ($r.text -match '\<strong\>Milk \(Fairlife\):\</strong\> 0 tbsp') $true
    Check 'fixture: milk was REPORTED'     (@($r.notes | Where-Object { $_ -match "'Milk'" }).Count) 1
    Check 'fixture: clean twin untouched'  ($r.text -match '\<strong\>Olive Oil:\</strong\> 3 tbsp') $true

    # the unit list must match what the sweep flags, or the two drift apart in silence
    $sweep = Join-Path $here 'spec-contradiction-lib.ps1'
    if (Test-Path $sweep) {
        $hasSame = (Select-String -Path $sweep -Pattern "0\\s\*\(lb\|lbs\|oz\|cups\?\|tbsp\|tsp\)" -Quiet)
        Check 'unit list agrees with the sweep' $hasSame $true
    }

    if ($script:fail -gt 0) { Write-Output "SELF-TEST FAILED ($script:fail)"; exit 1 }
    Write-Output 'self-test OK'
    exit 0
}

# ---------------------------------------------------------------- catalog pass

Initialize-FriendlyAmt -Root $mp
$specDir = Join-Path $mp 'db\recipes'
$touched = New-Object System.Collections.Generic.List[object]
$carry   = New-Object System.Collections.Generic.List[object]
$changedSpecs = 0

foreach ($sf in (Get-ChildItem (Join-Path $specDir '*.json') | Sort-Object Name)) {
    $io = Read-SpecText -Path $sf.FullName
    $spec = $io.Text | ConvertFrom-Json
    $r = Repair-SpecZeroQty -Raw $io.Text -Spec $spec
    foreach ($n in $r.notes) { Write-Output ("  note {0}: {1}" -f $sf.BaseName, $n) }
    if ($r.changed -eq 0) { continue }
    $changedSpecs++
    foreach ($e in $r.edits) {
        $touched.Add([pscustomobject]@{ slug = $sf.BaseName; item = $e.Item; old = $e.Old; new = $e.New })
        # recipes-db restates buy. "0 oz" is not provably FALSE (3 g really does round to 0 oz), so
        # sync-recipesdb-buy will not derive this edit on its own - the carry manifest is the whole
        # trigger, same shape and same channel as the measure-vs-grams and absurd-unit lanes.
        $carry.Add([pscustomobject]@{ slug = $sf.BaseName; item = $e.Item; old = $e.Old; new = $e.New })
    }
    if ($Apply) { Write-SpecText -Path $sf.FullName -Text $r.text -Bom $io.Bom }
}

foreach ($t in $touched) { Write-Output ("  {0,-46} {1,-22} '{2}' -> '{3}'" -f $t.slug, $t.item, $t.old, $t.new) }
Write-Output ("zero-qty repair: {0} label(s) across {1} spec(s){2}" -f $touched.Count, $changedSpecs, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))

if ($Apply -and $touched.Count) {
    $outDir = Join-Path $mp 'out'
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    [IO.File]::WriteAllText((Join-Path $outDir 'zero-qty-carry.json'), (@($carry.ToArray()) | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $outDir 'zero-qty-slugs.txt'), (($touched.slug | Sort-Object -Unique) -join "`n"), (New-Object Text.UTF8Encoding($false)))
    Write-Output ("  carry manifest -> out\zero-qty-carry.json ({0} row(s))" -f $carry.Count)
    Write-Output ("  slugs          -> out\zero-qty-slugs.txt")
}
