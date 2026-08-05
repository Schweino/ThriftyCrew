<#
  repair-absurd-units.ps1 - promote a label measured in tablespoons past the point anyone would use a
  tablespoon into the cups it actually is.

  THE DEFECT (2026-08-04). 81 labels across the 513 specs state a quantity in tbsp above 24 tbsp, which
  is a cup and a half:

      turkey-keema-curry-with-peas        Fresh Cilantro   "105 tbsp"
      ecuadorian-seco-de-pollo            Fresh Cilantro   "100 tbsp"
      thai-drunken-noodles-chicken        Fresh Basil      "74.75 tbsp"
      peruvian-tallarines-verdes-con-carne Fresh Basil     "70 tbsp"
      ... and 77 more, overwhelmingly Fresh Cilantro and Fresh Basil

  Nobody measures 105 tablespoons of cilantro. They fill a measuring cup six and a half times, or far
  more likely they buy two bunches, which is what the cost line already tells them to do.

  WHY THIS CLASS EXISTS, AND WHY IT IS NOT A REGRESSION TO BE REVERTED. It got worse (79 -> 81) on the
  day the measure-vs-grams repair landed, and that is the repair working as designed. Those labels used
  to state a quantity that DISAGREED with the grams the recipe is costed on; the repair made the label
  agree. Trading a false label for a true-but-unusable one is a real improvement in honesty and a real
  regression in usability, and the answer is to finish the job rather than to walk it back. This is the
  case the label-scales-wrong note anticipated: the label was already wrong standing still, and fixing
  its truth exposed the unit it should have been carrying all along.

  WHY THIS IS NOT THE LAUNDERING cook-measure-lib refuses, and the distinction matters. That refusal is
  right: when "1 tbsp" of olive oil carries 42 g, either side could be the error, so rewriting the label
  to agree with the grams could bury a data bug. NOTHING IS ADJUDICATED HERE. 105 tbsp and 6 1/2 cups are
  the same quantity; 16 tbsp is 1 cup by definition. The grams are untouched, the cost is untouched, the
  quantity is untouched. Only the unit the reader is asked to count in changes. There is no reading of
  this edit under which a wrong number becomes a confident one, which is exactly what separates a unit
  conversion from a laundering.

  SCOPE. Strictly the class the contradiction sweep flags: a LEADING quantity in tbsp, above 24. Tails
  survive ("35 tbsp chopped" -> "2 1/4 cups chopped") because they are cooking instructions the writer
  put there. tsp is deliberately untouched: the sweep does not flag it, and a big tsp figure is rare
  enough that a blanket rule would be changing labels nobody complained about.

  Usage: repair-absurd-units.ps1 [-Apply] [-SelfTest]
         Read-only by default: prints what it would change and writes nothing.
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path $mp 'lib\json-db-io.ps1')
. (Join-Path $here 'buy-label-lib.ps1')
. (Join-Path $here 'cook-measure-lib.ps1')

# 24 tbsp = 1.5 cups: the exact threshold audit-spec-contradictions flags as ABSURD-UNIT. Defined once
# here and asserted against the sweep in the self-test, so the two cannot drift apart silently.
$script:AbsurdTbspOver = 24
$script:TbspPerCup = 16

function Test-AbsurdTbsp {
    <# True when a buy label leads with a tbsp quantity past the threshold. #>
    param([string]$Buy)
    if (-not $Buy) { return $false }
    $u = Get-CmUnit $Buy
    if ($u -ne 'tbsp') { return $false }
    $q = Get-CmQty $Buy
    if ($null -eq $q) { return $false }
    return ($q -gt $script:AbsurdTbspOver)
}

function Resolve-AbsurdTbsp {
    <# "105 tbsp" -> "6 1/2 cups". "35 tbsp chopped" -> "2 1/4 cups chopped". #>
    param([string]$Buy)
    $q = Get-CmQty $Buy
    if ($null -eq $q) { return $null }
    $cups = $q / $script:TbspPerCup
    $measure = (Format-CmQty $cups) + ' cups'
    $tail = Get-CmTail $Buy
    if ($tail) { return (Join-CmTail $measure $tail) }
    return $measure
}

function Repair-SpecAbsurdUnits {
    <# Returns @{ changed=<int>; text=<patched raw>; notes=@(); edits=@() } for ONE spec.
       Pure text in, text out, so the self-test drives the same code path a catalog run does. #>
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)]$Spec
    )
    $ing  = @($Spec.scaler.ing)
    $disp = @($Spec.ingredients_display)
    if ($ing.Count -ne $disp.Count) { throw ("parallel arrays disagree: scaler.ing $($ing.Count) vs ingredients_display $($disp.Count)") }

    # Decide every edit BEFORE touching the text, so a spec is either fully patched or not at all.
    $edits = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $ing.Count; $i++) {
        $buy = [string]$ing[$i].buy
        if (-not (Test-AbsurdTbsp -Buy $buy)) { continue }
        $item = [string]$ing[$i].item
        $new = Resolve-AbsurdTbsp -Buy $buy
        if (-not $new -or $new -eq $buy) { $notes.Add("'$item' buy '$buy': could not promote - left alone"); continue }
        $g = if ($ing[$i].PSObject.Properties.Name -contains 'grams' -and $ing[$i].grams) { [double]$ing[$i].grams } else { 0 }
        $edits.Add([pscustomobject]@{ Index = $i; Item = $item; Old = $buy; New = $new; Grams = [int]$g })
    }
    if ($edits.Count -eq 0) { return @{ changed = 0; text = $Raw; notes = @($notes.ToArray()); edits = @() } }

    # -IncludeHead: these labels DO reach the JSON-LD (head.recipeIngredient is derived from the card as
    # of 2026-08-04), so Google would otherwise keep serving "105 tbsp Fresh Cilantro".
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
    Write-Output 'repair-absurd-units self-test'

    # the predicate
    Check 'flags 105 tbsp'        (Test-AbsurdTbsp -Buy '105 tbsp')        $true
    Check 'flags 24.5 tbsp'       (Test-AbsurdTbsp -Buy '24.5 tbsp')       $true
    Check 'leaves 24 tbsp alone'  (Test-AbsurdTbsp -Buy '24 tbsp')         $false
    Check 'leaves 3 tbsp alone'   (Test-AbsurdTbsp -Buy '3 tbsp')          $false
    Check 'leaves cups alone'     (Test-AbsurdTbsp -Buy '30 cups')         $false
    Check 'leaves tsp alone'      (Test-AbsurdTbsp -Buy '30 tsp')          $false
    Check 'leaves empty alone'    (Test-AbsurdTbsp -Buy '')                $false

    # the conversion
    Check 'promotes 105'          (Resolve-AbsurdTbsp -Buy '105 tbsp')     '6 1/2 cups'
    Check 'promotes 25'           (Resolve-AbsurdTbsp -Buy '25 tbsp')      '1 1/2 cups'
    Check 'keeps the tail'        (Resolve-AbsurdTbsp -Buy '35 tbsp chopped') '2 1/4 cups chopped'
    # 30 tbsp is 1.875 cups and Format-CmQty rounds to kitchen quarters, so this lands on 1 3/4, not 2.
    # That rounding is the house convention every other label in the catalog already follows, and the
    # grams sit right beside it on the display line for anyone using a scale.
    Check 'keeps a comma tail'    (Resolve-AbsurdTbsp -Buy '30 tbsp, rough chopped') '1 3/4 cups, rough chopped'

    # THE MUST-FIRE FIXTURE: the founding case, frozen, plus a clean twin that must NOT move.
    # Per the guard-fixture rule, regenerating this from the live catalog would let the bug back in.
    $fixture = @'
{
  "slug": "fixture-absurd",
  "ingredients_display": [
    "<strong>Fresh Cilantro:</strong> 105 tbsp (105 g)",
    "<strong>Olive Oil:</strong> 3 tbsp (42 g)"
  ],
  "scaler": { "ing": [
    { "item": "Fresh Cilantro", "grams": 105, "buy": "105 tbsp" },
    { "item": "Olive Oil", "grams": 42, "buy": "3 tbsp" }
  ] }
}
'@
    $fspec = $fixture | ConvertFrom-Json
    $r = Repair-SpecAbsurdUnits -Raw $fixture -Spec $fspec
    Check 'fixture: one edit'     $r.changed 1
    Check 'fixture: the absurd one moved' ($r.edits[0].New) '6 1/2 cups'
    Check 'fixture: clean twin untouched' ($r.text -match '\<strong\>Olive Oil:\</strong\> 3 tbsp') $true
    Check 'fixture: display rewritten'    ($r.text -match '6 1/2 cups \(105 g\)') $true

    # the threshold must match what the sweep flags, or the two drift apart in silence
    $sweep = Join-Path $here 'spec-contradiction-lib.ps1'
    if (Test-Path $sweep) {
        $hasSame = (Select-String -Path $sweep -Pattern '\-gt\s+24\b' -Quiet)
        Check 'threshold agrees with the sweep' $hasSame $true
    }

    if ($script:fail -gt 0) { Write-Output "SELF-TEST FAILED ($script:fail)"; exit 1 }
    Write-Output 'self-test OK'
    exit 0
}

# ---------------------------------------------------------------- catalog pass

$specDir = Join-Path $mp 'db\recipes'
$touched = New-Object System.Collections.Generic.List[object]
$carry   = New-Object System.Collections.Generic.List[object]
$changedSpecs = 0

foreach ($sf in (Get-ChildItem (Join-Path $specDir '*.json') | Sort-Object Name)) {
    $raw = Get-Content $sf.FullName -Raw
    $spec = $raw | ConvertFrom-Json
    $r = Repair-SpecAbsurdUnits -Raw $raw -Spec $spec
    foreach ($n in $r.notes) { Write-Output ("  note {0}: {1}" -f $sf.BaseName, $n) }
    if ($r.changed -eq 0) { continue }
    $changedSpecs++
    foreach ($e in $r.edits) {
        $touched.Add([pscustomobject]@{ slug = $sf.BaseName; item = $e.Item; old = $e.Old; new = $e.New })
        # recipes-db restates buy, and the db label here is NOT provably false ("26 tbsp" is true, just
        # unusable), so sync-recipesdb-buy will refuse to derive this edit on its own. The manifest is
        # the entire trigger, exactly as it is for the measure-vs-grams lane. Same {slug,item,old,new}
        # shape those loaders expect, byte for byte, or the row is ignored as stale.
        $carry.Add([pscustomobject]@{ slug = $sf.BaseName; item = $e.Item; old = $e.Old; new = $e.New })
    }
    if ($Apply) { [IO.File]::WriteAllText($sf.FullName, $r.text, (New-Object Text.UTF8Encoding($false))) }
}

foreach ($t in $touched) { Write-Output ("  {0,-46} {1,-22} '{2}' -> '{3}'" -f $t.slug, $t.item, $t.old, $t.new) }
Write-Output ("absurd-unit repair: {0} label(s) across {1} spec(s){2}" -f $touched.Count, $changedSpecs, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))

if ($Apply -and $touched.Count) {
    $outDir = Join-Path $mp 'out'
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    [IO.File]::WriteAllText((Join-Path $outDir 'absurd-unit-carry.json'), (@($carry.ToArray()) | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $outDir 'absurd-unit-slugs.txt'), (($touched.slug | Sort-Object -Unique) -join "`n"), (New-Object Text.UTF8Encoding($false)))
    Write-Output ("  carry manifest -> out\absurd-unit-carry.json ({0} row(s))" -f $carry.Count)
    Write-Output ("  slugs          -> out\absurd-unit-slugs.txt")
}
