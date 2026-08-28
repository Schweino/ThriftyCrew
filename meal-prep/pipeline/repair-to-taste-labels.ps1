<#
  repair-to-taste-labels.ps1 - a seasoning the SOURCE never quantified gets the label the source gave it.

  THE DEFECT. Three live labels state a false precision for an amount the original recipe never stated:

      peruvian-pollo-saltado               Salt        "0.06 tbsp"  (1 g)
      steak-fajita-rice-bowls              Salt        "0.06 tbsp"  (1 g)
      chile-relleno-casserole-ground-beef  Hot Sauce   "0.07 tbsp"  (1 g)

  Each is UNMEASURABLE-QTY, and repair-unmeasurable-qty correctly refuses all three: 1 g of salt is a
  sixth of a teaspoon and 1 g of hot sauce a fifth, so there is no unit that makes them measurable. Its
  note says "the grams are the question" - and the grams turn out to be a PLACEHOLDER, not a measurement.
  The 1 g is what the intake assigns to an ingredient with no stated amount, and printing it as
  "0.06 tbsp" invents a precision the source never had.

  THE EVIDENCE, one per row, checked against the source and the recipe's own prose:
    peruvian-pollo-saltado   step 7 says "taste for salt and vinegar" - the recipe itself says to season
                             by taste, and never states an amount anywhere.
    steak-fajita-rice-bowls  isabeleats.com/easy-steak-fajitas lists the marinade line verbatim as
                             "kosher salt and black pepper", with no quantity, and gives the vegetables
                             "1 pinch kosher salt".
    chile-relleno-...        step 6 says "a dash of hot sauce". A dash IS the amount; 0.07 tbsp is that
                             same dash pretending to be a measurement.

  SO THIS IS NOT A UNIT CONVERSION and it does not belong in repair-unmeasurable-qty, whose whole contract
  is "only the unit the reader counts in changes". This changes the KIND of claim the label makes, from a
  quantity to an instruction, and it may only be done where the source is silent on the quantity. That is
  a per-row ruling with per-row evidence, so the rows are named here rather than found by a rule.

  THE GRAMS ARE NOT TOUCHED. 1 g stays the costing and macro basis, exactly as it is for the 59 rows the
  catalog already labels "to taste" - which is where the wording comes from, not from this script.

  WHAT THIS DELIBERATELY DOES NOT DO. steak-fajita's Black Pepper carries 7 g / "1 tbsp" from the same
  source line that gave salt no quantity, so that figure is invented too. It is MEASURABLE, so no gate
  reports it, and correcting it is a fidelity question about grams rather than a label question. It is
  written up rather than quietly changed here.

  Usage: repair-to-taste-labels.ps1 [-Apply] [-SelfTest]
         Read-only by default: prints what it would change and writes nothing.
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path $mp 'lib\json-db-io.ps1')   # Find-JsonValueStart, which the splice below needs
. (Join-Path $here 'buy-label-lib.ps1')
. (Join-Path $here 'cook-measure-lib.ps1')

# THE RULINGS. slug -> item -> the label that replaces the false precision. Named, not matched: every
# entry above carries its own evidence, and a rule that found these by shape would also find the rows
# where the source DID state an amount and the grams are simply wrong.
$script:ToTaste = @{
  'peruvian-pollo-saltado'              = @{ 'Salt'      = 'to taste' }
  'steak-fajita-rice-bowls'             = @{ 'Salt'      = 'to taste' }
  'chile-relleno-casserole-ground-beef' = @{ 'Hot Sauce' = 'to taste' }
}

function Get-ToTasteEdits {
  <# Returns the edit list for ONE spec, or an empty list. Pure: spec in, decisions out. #>
  param([Parameter(Mandatory)][string]$Slug, [Parameter(Mandatory)]$Spec)
  $edits = New-Object System.Collections.Generic.List[object]
  if (-not $script:ToTaste.ContainsKey($Slug)) { return $edits }
  $want = $script:ToTaste[$Slug]
  $ing = @($Spec.scaler.ing)
  for ($i = 0; $i -lt $ing.Count; $i++) {
    $item = [string]$ing[$i].item
    if (-not $want.ContainsKey($item)) { continue }
    $buy = [string]$ing[$i].buy
    $new = [string]$want[$item]
    if (-not $buy -or $buy -eq $new) { continue }
    # REFUSE A ROW THAT IS ALREADY MEASURABLE. The ruling is "the source stated no amount", and the only
    # rows it may touch are the ones carrying the placeholder. If a recost ever gives this ingredient a
    # real quantity, this script must go quiet rather than overwrite it with an instruction.
    $q = Get-CmQty $buy
    if ($null -eq $q -or $q -ge 0.25) { continue }
    $edits.Add([pscustomobject]@{ Index = $i; Item = $item; Old = $buy; New = $new; Grams = [int]$ing[$i].grams })
  }
  return $edits
}

if ($SelfTest) {
  $fail = 0
  function Chk([string]$label, [bool]$cond, [string]$got) {
    if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
  }
  # FROZEN FIXTURE - peruvian-pollo-saltado's shape, with a measurable twin beside it.
  $fx = [pscustomobject]@{ scaler = [pscustomobject]@{ ing = @(
    [pscustomobject]@{ item = 'Salt';         grams = 1;  buy = '0.06 tbsp' },
    [pscustomobject]@{ item = 'Black Pepper'; grams = 7;  buy = '1 tbsp' }) } }
  $e = @(Get-ToTasteEdits -Slug 'peruvian-pollo-saltado' -Spec $fx)
  Chk 'MUST FIRE  the 1 g placeholder salt becomes "to taste"' ($e.Count -eq 1 -and $e[0].Item -eq 'Salt' -and $e[0].New -eq 'to taste') (($e | ForEach-Object { $_.Item + '->' + $_.New }) -join ' | ')
  Chk 'CLEAN TWIN a measurable pepper on the same spec is untouched' (@($e | Where-Object { $_.Item -eq 'Black Pepper' }).Count -eq 0) (($e | ForEach-Object { $_.Item }) -join ' | ')
  # THE SCOPE FLOOR. A slug that is not in the ruling table gets nothing, however similar it looks -
  # this repair is a list of adjudicated rows, not a shape matcher.
  $e2 = @(Get-ToTasteEdits -Slug 'some-other-recipe' -Spec $fx)
  Chk 'MUST NOT FIRE  an unadjudicated slug is left entirely alone' ($e2.Count -eq 0) (($e2 | ForEach-Object { $_.Item }) -join ' | ')
  # THE RECOST GUARD. If Salt ever gets a real amount, the ruling must go quiet, not overwrite it.
  $fx2 = [pscustomobject]@{ scaler = [pscustomobject]@{ ing = @(
    [pscustomobject]@{ item = 'Salt'; grams = 26; buy = '1.5 tbsp' }) } }
  $e3 = @(Get-ToTasteEdits -Slug 'peruvian-pollo-saltado' -Spec $fx2)
  Chk 'MUST NOT FIRE  a salt row that now carries a REAL amount is not overwritten' ($e3.Count -eq 0) (($e3 | ForEach-Object { $_.Old + '->' + $_.New }) -join ' | ')
  # IDEMPOTENT. A second pass over an already-repaired row must find nothing.
  $fx3 = [pscustomobject]@{ scaler = [pscustomobject]@{ ing = @(
    [pscustomobject]@{ item = 'Salt'; grams = 1; buy = 'to taste' }) } }
  $e4 = @(Get-ToTasteEdits -Slug 'peruvian-pollo-saltado' -Spec $fx3)
  Chk 'idempotent - an already-repaired row is not re-edited' ($e4.Count -eq 0) (($e4 | ForEach-Object { $_.Old }) -join ' | ')
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$total = 0; $touched = 0
$slugs = New-Object System.Collections.Generic.List[string]
foreach ($slug in ($script:ToTaste.Keys | Sort-Object)) {
  $f = Join-Path $mp ("db\recipes\$slug.json")
  if (-not (Test-Path $f)) { Write-Output ("  MISSING  $slug"); continue }
  $raw = Get-Content $f -Raw
  $spec = $raw | ConvertFrom-Json
  $edits = @(Get-ToTasteEdits -Slug $slug -Spec $spec)
  if ($edits.Count -eq 0) { continue }
  foreach ($e in $edits) { Write-Output ("  {0,-38} {1,-12} '{2}' -> '{3}'" -f $slug, $e.Item, $e.Old, $e.New) }
  # -IncludeHead: head.recipeIngredient is derived from the card, so the JSON-LD would otherwise keep
  # serving "Salt, 0.06 tbsp" to Google after the page stopped saying it.
  $sp = Invoke-BuyLabelSplice -Raw $raw -Spec $spec -Edits $edits -IncludeHead
  foreach ($n in $sp.notes) { Write-Output ('      note ' + $n) }
  $total += $edits.Count; $touched++
  $slugs.Add($slug)
  if ($Apply) { Set-Content $f $sp.text -Encoding UTF8 -NoNewline }
}
Write-Output ("to-taste labels: {0} label(s) across {1} spec(s){2}" -f $total, $touched, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))
if ($Apply -and $slugs.Count) {
  ($slugs.ToArray()) -join "`n" | Set-Content (Join-Path $mp 'out\to-taste-slugs.txt') -Encoding UTF8
  Write-Output '  slugs -> out\to-taste-slugs.txt (rebuild + republish these cards)'
}
exit 0
