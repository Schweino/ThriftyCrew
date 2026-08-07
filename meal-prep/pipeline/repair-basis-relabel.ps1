<#
  repair-basis-relabel.ps1 - re-derive the ingredient labels that were written against a cup/tbsp basis
  db\densities.json has since CORRECTED.

  WHY. densities.json and food-macros-db.json both state what a household unit of an item weighs, and on
  2026-08-07 a comparison of the two found 13 items where they disagreed. Five of those were settled by
  moving densities onto the transcribed product label (Salsa, Salsa Verde, Coconut Milk, Teriyaki Sauce,
  Parmesan Cheese - see db\densities.json basis_reconciliation_2026_08_07). Every label already in the
  catalog for those items was derived against the OLD number, so it now states an amount the estate no
  longer believes. The grams are untouched and correct; the sentence in front of them is stale.

  THE GATE, which is the whole design. A basis change is not a licence to rewrite every label for that
  item, because not every label came from the generator. The catalog also holds labels a writer typed off
  a source recipe ("7/8 cup grated", "2 jars", "1 cup chunky tomato salsa (per 4)"), and those are
  measurements of a DIFFERENT recipe or a package claim - repair-measure-vs-grams.ps1 exists precisely
  because deciding which side of that is wrong needs the source, not arithmetic. So a row is rewritten
  ONLY when its stored label is byte-identical to what the generator produced under the OLD basis. That
  proves the generator wrote it, which is what makes re-deriving it a no-judgement operation.

  The proof comes from a PRE-IMAGE captured before densities moved (out\basis-preimage-*.json: slug,
  canon, grams, stored, derived_old). Without that file this script does nothing at all - it cannot
  reconstruct the old basis from a file that no longer holds it, and guessing is how a sweep launders a
  hand-written label into machine output. 23 of the 101 rows in the founding pre-image failed this gate
  and were left exactly as they are.

  NO GRAM FIGURE, COST FIELD OR MACRO MOVES. Only the sentence.

  Same four surfaces and same tail as every other label repair - see engine\README.md.

  Read-only unless -Apply.
  Usage: .\repair-basis-relabel.ps1 -PreImage out\basis-preimage-2026-08-07.json [-Apply] | -SelfTest
#>
param([string]$PreImage, [switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path $mp 'lib\json-db-io.ps1')
. (Join-Path $here 'buy-label-lib.ps1')
. (Join-Path $here 'friendly-amt-lib.ps1')

function Get-PreImageMap {
    <# slug|canon|grams -> the label the generator produced under the OLD basis. Keyed on grams too,
       because one recipe can carry the same item twice at different amounts. #>
    param([Parameter(Mandatory)][string]$Path)
    $m = @{}
    foreach ($r in @((Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json))) {
        if (-not $r -or -not $r.slug) { continue }
        $m[([string]$r.slug + '|' + [string]$r.canon + '|' + [int][double]$r.grams)] = [pscustomobject]@{
            Stored = [string]$r.stored; DerivedOld = [string]$r.derived_old
        }
    }
    return $m
}

function Resolve-BasisRelabel {
    <# The new label for one row, or $null when the gate refuses it. #>
    param(
        [Parameter(Mandatory)][string]$Canon, [Parameter(Mandatory)][double]$Grams,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Buy, [Parameter(Mandatory)][AllowNull()]$Pre
    )
    if (-not $Pre) { return $null }                              # not in the pre-image: not this sweep's row
    if ($Grams -le 0 -or -not $Buy) { return $null }
    # THE GATE. The label in the file must still be the one the pre-image saw AND that label must be
    # exactly what the generator wrote under the old basis. Either half failing means a human is involved.
    if ([string]$Pre.Stored -ne $Buy) { return $null }
    if ([string]$Pre.DerivedOld -ne $Buy) { return $null }
    $new = $null
    try { $new = Get-FriendlyAmt $Canon $Grams } catch { return $null }
    if (-not $new -or $new -eq $Buy) { return $null }
    return $new
}

function Repair-SpecBasisRelabel {
    param([Parameter(Mandatory)][string]$Raw, [Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][AllowNull()]$Pre, [string]$Slug)
    $ing  = @($Spec.scaler.ing)
    $disp = @($Spec.ingredients_display)
    if ($ing.Count -ne $disp.Count) { throw ("parallel arrays disagree: scaler.ing $($ing.Count) vs ingredients_display $($disp.Count)") }
    $edits = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $ing.Count; $i++) {
        $buy = [string]$ing[$i].buy
        if (-not $buy) { continue }
        $canon = if (($ing[$i].PSObject.Properties.Name -contains 'canon') -and $ing[$i].canon) { [string]$ing[$i].canon } else { [string]$ing[$i].item }
        $dispName = [string]$ing[$i].item
        $g = if (($ing[$i].PSObject.Properties.Name -contains 'grams') -and $ing[$i].grams) { [double]$ing[$i].grams } else { 0 }
        $key = $Slug + '|' + $canon + '|' + [int]$g
        $p = if ($Pre -and $Pre.ContainsKey($key)) { $Pre[$key] } else { $null }
        $new = Resolve-BasisRelabel -Canon $canon -Grams $g -Buy $buy -Pre $p
        if (-not $new) { continue }
        # cost_lines carry the DISPLAY name; densities and recipes-db are keyed by CANON.
        $edits.Add([pscustomobject]@{ Index = $i; Item = $dispName; Canon = $canon; Old = $buy; New = $new; Grams = [int]$g })
    }
    if ($edits.Count -eq 0) { return @{ changed = 0; text = $Raw; notes = @(); edits = @() } }
    $sp = Invoke-BuyLabelSplice -Raw $Raw -Spec $Spec -Edits @($edits.ToArray()) -IncludeHead
    return @{ changed = $edits.Count; text = $sp.text; notes = @($sp.notes); edits = @($edits.ToArray()) }
}

if ($SelfTest) {
    $fail = 0
    function Chk([string]$label, [bool]$cond, [string]$got) {
        if ($cond) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + '   got: ' + $got); $script:fail++ }
    }
    Write-Output 'repair-basis-relabel self-test'
    Initialize-FriendlyAmt -Root $mp

    # Salsa moved 260 -> 240 g/cup. 280 g was "1 cup" under the old basis and is "1.25 cups" under the new.
    $ok = [pscustomobject]@{ Stored = '1 cup'; DerivedOld = '1 cup' }
    Chk 'relabels a generator-written row' ((Resolve-BasisRelabel -Canon 'Salsa' -Grams 280 -Buy '1 cup' -Pre $ok) -eq '1.25 cups') (Resolve-BasisRelabel -Canon 'Salsa' -Grams 280 -Buy '1 cup' -Pre $ok)
    # THE GATE, both halves. A hand-written label never matched the generator, so DerivedOld differs.
    $hand = [pscustomobject]@{ Stored = '7/8 cup grated'; DerivedOld = '1 cup' }
    Chk 'REFUSES a hand-written label'     ($null -eq (Resolve-BasisRelabel -Canon 'Salsa' -Grams 280 -Buy '7/8 cup grated' -Pre $hand)) 'a hand-written label was swept'
    # The spec moved between the pre-image and now: refuse, the pre-image no longer describes this row.
    $stale = [pscustomobject]@{ Stored = '1 cup'; DerivedOld = '1 cup' }
    Chk 'REFUSES when the spec moved'      ($null -eq (Resolve-BasisRelabel -Canon 'Salsa' -Grams 280 -Buy '2 cups' -Pre $stale)) 'a moved row was rewritten off a stale pre-image'
    Chk 'REFUSES a row with no pre-image'  ($null -eq (Resolve-BasisRelabel -Canon 'Salsa' -Grams 280 -Buy '1 cup' -Pre $null)) 'a row outside the pre-image was swept'
    # An item whose basis did NOT move must produce no edit at all.
    $noMove = [pscustomobject]@{ Stored = '3.75 cups dry'; DerivedOld = '3.75 cups dry' }
    Chk 'no edit when the basis did not move' ($null -eq (Resolve-BasisRelabel -Canon 'Rice' -Grams 700 -Buy '3.75 cups dry' -Pre $noMove)) 'rewrote a row whose basis is unchanged'

    # FROZEN FIXTURE: one generator row that must move, one hand-written twin that must not.
    $fx = @'
{
    "slug":  "fx-basis",
    "intro_html":  "Prose with a brace { a bracket [ and a quote \" so the splice stays string-aware.",
    "ingredients_display": ["<strong>Salsa (Pace):</strong> 1 cup (280 g)","<strong>Salsa Verde:</strong> 7/8 cup grated (280 g)"],
    "cost_lines":  ["Salsa, 1 cup: ~$0.97. <strong>Buy 1 jar: $2.59.</strong>"],
    "scaler":  { "ing":  [
        { "item": "Salsa",       "canon": "Salsa",       "grams": 280, "buy": "1 cup",          "bid": "salsa",       "gpu": "28.350" },
        { "item": "Salsa Verde", "canon": "Salsa Verde", "grams": 280, "buy": "7/8 cup grated", "bid": "salsa-verde", "gpu": "28.350" }
    ] }
}
'@
    $pre = @{ 'fx-basis|Salsa|280' = [pscustomobject]@{ Stored = '1 cup'; DerivedOld = '1 cup' }
              'fx-basis|Salsa Verde|280' = [pscustomobject]@{ Stored = '7/8 cup grated'; DerivedOld = '1 cup' } }
    $r = Repair-SpecBasisRelabel -Raw $fx -Spec ($fx | ConvertFrom-Json) -Pre $pre -Slug 'fx-basis'
    Chk 'fixture: exactly one edit'        ($r.changed -eq 1) ("changed=" + $r.changed)
    Chk 'fixture: display rewritten'       ($r.text -match '\<strong\>Salsa \(Pace\):\</strong\> 1.25 cups \(280 g\)') 'display not rewritten'
    Chk 'fixture: cost_line followed'      ($r.text -match 'Salsa, 1.25 cups: ') 'cost_lines not spliced'
    Chk 'fixture: hand-written twin intact'($r.text -match '7/8 cup grated \(280 g\)') 'hand-written twin was swept'
    Chk 'fixture: still valid JSON'        ($null -ne ($r.text | ConvertFrom-Json)) 'splice produced unparseable JSON'
    Assert-BuyLabelSurfacesAgree -Text $r.text -Slug 'fx-basis'
    Chk 'fixture: surfaces agree'          $true ''
    if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

if (-not $PreImage) { throw 'a -PreImage file is required: this sweep cannot reconstruct the old basis, and guessing it would launder hand-written labels into machine output' }
if (-not [System.IO.Path]::IsPathRooted($PreImage)) { $PreImage = Join-Path $mp $PreImage }
if (-not (Test-Path $PreImage)) { throw ("pre-image not found: $PreImage") }
Initialize-FriendlyAmt -Root $mp
$pre = Get-PreImageMap -Path $PreImage
Write-Output ("pre-image: {0} row(s) from {1}" -f $pre.Count, (Split-Path $PreImage -Leaf))

$lines = 0; $recipes = 0
$slugs = New-Object System.Collections.Generic.List[string]
$samples = New-Object System.Collections.Generic.List[string]
$carry = New-Object System.Collections.Generic.List[object]
foreach ($f in @(Get-ChildItem (Join-Path $mp 'db\recipes\*.json') | Where-Object { $_.Name -ne '_index.json' })) {
    $io = Read-SpecText $f.FullName
    $spec = $io.Text | ConvertFrom-Json
    if (-not $spec.scaler -or -not $spec.scaler.ing) { continue }
    $r = Repair-SpecBasisRelabel -Raw $io.Text -Spec $spec -Pre $pre -Slug $f.BaseName
    if ($r.changed -eq 0) { continue }
    foreach ($e in $r.edits) {
        if ($samples.Count -lt 20) { $samples.Add(("{0,-40} {1,-18} {2,5} g  '{3}' -> '{4}'" -f $f.BaseName, $e.Canon, $e.Grams, $e.Old, $e.New)) }
        $carry.Add([pscustomobject]@{ slug = $f.BaseName; item = $e.Canon; old = $e.Old; new = $e.New })
    }
    Assert-BuyLabelSurfacesAgree -Text $r.text -Slug $f.BaseName
    $lines += $r.changed; $recipes++; $slugs.Add($f.BaseName)
    if ($Apply) { Write-SpecText -Path $f.FullName -Text $r.text -Bom $io.Bom }
}
Write-Output ("basis relabel: {0} line(s) across {1} recipe(s){2}" -f $lines, $recipes, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))
foreach ($s in $samples) { Write-Output ('    ' + $s) }
if ($Apply -and $slugs.Count) {
    New-Item -ItemType Directory -Force (Join-Path $mp 'out') | Out-Null
    ($slugs -join "`n") | Set-Content (Join-Path $mp 'out\basis-relabel-slugs.txt') -Encoding UTF8
    $json = if ($carry.Count -eq 1) { '[' + ($carry[0] | ConvertTo-Json -Depth 4 -Compress) + ']' } else { $carry | ConvertTo-Json -Depth 4 }
    $json | Set-Content (Join-Path $mp 'out\basis-relabel-carry.json') -Encoding UTF8
    Write-Output ("  slugs -> out\basis-relabel-slugs.txt ; carry manifest -> out\basis-relabel-carry.json ({0} row(s))" -f $carry.Count)
}
exit 0
