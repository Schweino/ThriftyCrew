<#
  friendly-amt-lib.ps1 - the label a card prints for a gram amount: "3 onions", "5 cups dry", "1.25 tbsp".

  WHY THIS FILE EXISTS. `FriendlyAmt` is the function that wrote most of the 5,574 measurable labels in
  db\recipes, and until now it lived as an inline copy in build-v2-spec.ps1 and a second inline copy in
  build-run-specs.ps1 (plus three frozen copies under archive\). Anything that needs to RE-derive a label
  - a repair sweep, a guard, a screen - had a choice between a fourth copy and hand-computing, and
  repair-scaled-notes.ps1 took the second road: it hand-wrote seven labels and then re-derived them in its
  self-test to prove they were what the builder would have said. That works for seven. It does not work
  for 331, and a fourth copy is how two surfaces start disagreeing about what a teaspoon is.

  So the logic moves here ONCE, and the callers dot-source it. The behaviour is a byte-for-byte port of
  build-v2-spec.ps1:151-203 as of 2026-08-04; Test-FriendlyAmtAgainstCatalog below re-derives real
  catalog labels through it and is the assertion that keeps the port honest.

  THE ORDER OF THE BRANCHES IS THE KNOWLEDGE. Each one is a lesson from a card that read wrong:
    broth   -> cartons or cups, never "4.25 lb" (r100 shipped that)
    meat    -> lb, never "14.25 cups of Turkey Breast" (r100 writer-wave finding)
    rice    -> "N cups dry", which is what 218 of the catalog's 289 rice rows already say
    pasta   -> "N oz dry"; cheese -> "N oz"
    can     -> only when the grams actually reach 85% of a can
    each    -> only for things big enough to count (>=40 g) - and the NOUN comes from db\each-nouns.json,
               because 'each' is overloaded in densities (Chicken Broth each = 240 g IS a cup)
    tbsp    -> under 120 g; cups above; ounces when nothing else is known
#>

$script:FA_LB = 453.592
$script:FA_OZ = 28.3495

function Initialize-FriendlyAmt {
    <# Load the two maps once. Pass paths to point at fixtures; defaults are the live db. #>
    param([string]$DensitiesFile, [string]$EachNounsFile, [string]$Root)
    $mp = if ($Root) { $Root } else { Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
    if (-not $DensitiesFile) { $DensitiesFile = Join-Path $mp 'db\densities.json' }
    if (-not $EachNounsFile) { $EachNounsFile = Join-Path $mp 'db\each-nouns.json' }
    $script:FA_DN = @{}
    foreach ($p in ((Get-Content $DensitiesFile -Raw | ConvertFrom-Json).items.PSObject.Properties)) { $script:FA_DN[$p.Name] = $p.Value }
    $script:FA_EN = @{}
    $en = Get-Content $EachNounsFile -Raw | ConvertFrom-Json
    $src = if ($en.PSObject.Properties.Name -contains 'items') { $en.items } else { $en }
    foreach ($p in $src.PSObject.Properties) {
        if ($p.Value -and ($p.Value.PSObject.Properties.Name -contains 'one')) { $script:FA_EN[$p.Name] = $p.Value }
    }
}

function Get-FaDen([string]$item, [string]$u) {
    if ($script:FA_DN.ContainsKey($item) -and ($script:FA_DN[$item].PSObject.Properties.Name -contains $u)) { return [double]$script:FA_DN[$item].$u }
    return $null
}

function Get-FaEachNoun([string]$item, [double]$n) {
    if (-not $script:FA_EN.ContainsKey($item)) {
        throw ("no each-noun for '$item' - it reaches the FriendlyAmt each branch, so it needs a {one, many} entry in db\each-nouns.json (otherwise the card prints a count with no unit)")
    }
    if ([Math]::Abs($n - 1.0) -lt 1e-9) { return [string]$script:FA_EN[$item].one }
    return [string]$script:FA_EN[$item].many
}

function Get-FaFrac([double]$v) {
    # quarters at a quarter-unit and above, 2 decimals below that so a small amount never prints "0"
    # (r100 shipped "Bay Leaves ... 0 oz").
    $r = [Math]::Round($v * 4) / 4
    if ($r -lt 0.25) { if ($v -le 0) { return '0' }; return ([Math]::Max([Math]::Round($v, 2), 0.01)).ToString('0.##') }
    if ($r -eq [Math]::Floor($r)) { return ([string][int]$r) }
    return $r.ToString('0.##')
}

$script:FA_WEIGHT_MEAT  = 'Chicken|Beef|Turkey|Pork|Sausage|Chorizo|Bacon|\bHam\b|Brisket|Liver|Bratwurst|Lamb|Veal'
$script:FA_WEIGHT_FIRST = 'Kale|Spinach|Cabbage|Mushrooms|Broccoli|Brussels|Sprouts|Green Beans|Snow Peas|Zucchini|Eggplant|Cauliflower|Collard|Bok Choy|Asparagus|Okra|Squash|Peas$|Corn$'
$script:FA_NOT_MEAT     = 'Broth|Stock|Soup|Bouillon|Seasoning|Powder|Sauce|Gravy|Rub|Bacon Bits'

function Get-FriendlyAmt {
    <#
      -Faithful reproduces build-v2-spec.ps1's inline FriendlyAmt exactly, and is what
      Test-FriendlyAmtAgainstCatalog grades against so the port stays pinned to the builder.

      THE DEFAULT ADDS ONE STEP THE BUILDER LACKS: a TEASPOON rung below the tablespoon.
      FriendlyAmt's small-amount branch is `if ($tb -and $g -lt 120) { ... ' tbsp' }` with nothing under
      it, so a spice lighter than one tablespoon prints as a FRACTION of one - "Black Pepper: 0.25 tbsp",
      "Ground Cumin: 0.75 tbsp". No cook owns a quarter-tablespoon measure; the spoon in the drawer is a
      teaspoon, and 0.25 tbsp IS 3/4 tsp. This is a unit conversion of the very same gram figure, not a
      new claim about the food - the weight does not move, only the spoon it is named in.
      Items with no tbsp density at all (Ground Ginger, Nutmeg, Allspice) used to fall through to the
      weight fallback and print "0.07 oz", which is not a thing anyone can measure either.
    #>
    param([string]$item, [double]$g, [switch]$Faithful)
    if (-not $Faithful) {
        # Only the small-measure tail changes; every branch above it is the builder's, untouched.
        $pre = Get-FriendlyAmtCore $item $g
        $u = ''
        $m = [regex]::Match([string]$pre, '(?i)^\s*(\d+(?:\.\d+)?)\s*([a-z]+)')
        if ($m.Success) {
            $q = [double]$m.Groups[1].Value; $u = $m.Groups[2].Value.ToLower()
            if (($u -eq 'tbsp' -and $q -lt 1) -or ($u -eq 'oz' -and $g -lt 30)) {
                $tsp = Get-FaDen $item 'tsp'
                if (-not $tsp) { $tb = Get-FaDen $item 'tbsp'; if ($tb) { $tsp = $tb / 3.0 } }
                if ($tsp -and $tsp -gt 0) {
                    $n = $g / $tsp
                    if ($n -ge 0.25 -and $n -lt 24) { return ((Get-FaFrac $n) + ' tsp') }
                }
            }
            # "1 cups" - Get-FaFrac returns the bare number and the branch appends a hardcoded plural, so
            # exactly one cup prints with an s. Small, but it is on the card.
            if ($u -eq 'cups' -and [math]::Abs($q - 1.0) -lt 1e-9) { return '1 cup' }
        }
        return $pre
    }
    return (Get-FriendlyAmtCore $item $g)
}

function Get-FriendlyAmtCore([string]$item, [double]$g) {
    if ($item -match 'Broth|Stock') {
        $cartons = Get-FaDen $item 'carton'
        if ($cartons -and $g -ge ($cartons * 0.85)) { $n = [Math]::Round($g / $cartons, 1); if ([Math]::Abs($n - [Math]::Round($n)) -lt 0.15) { $n = [Math]::Round($n) }; return ("$n carton" + $(if ($n -ne 1) { 's' })) }
        return ((Get-FaFrac ($g / 240.0)) + ' cups')
    }
    if ($item -match $script:FA_WEIGHT_MEAT -and $item -notmatch $script:FA_NOT_MEAT) { return ((Get-FaFrac ($g / $script:FA_LB)) + ' lb') }
    if ($item -eq 'Rice')  { return ((Get-FaFrac ($g / 185.0)) + ' cups dry') }
    if ($item -eq 'Eggs')  { return ([string][int][Math]::Round($g / 50.0) + ' large eggs') }
    if ($item -match 'Pasta|Spaghetti|Ziti|Fettuccine|Orzo|Noodles|Gnocchi|Tortellini|Shells') { return ((Get-FaFrac ($g / $script:FA_OZ)) + ' oz dry') }
    if ($item -match 'Cheese|Mozzarella|Cheddar|Feta|Parmesan|Ricotta') { return ((Get-FaFrac ($g / $script:FA_OZ)) + ' oz') }
    $can = Get-FaDen $item 'can'
    if ($can -and $g -ge ($can * 0.85)) { $n = [Math]::Round($g / $can, 1); if ([Math]::Abs($n - [Math]::Round($n)) -lt 0.15) { $n = [Math]::Round($n) }; return ("$n can" + $(if ($n -ne 1) { 's' })) }
    $each = Get-FaDen $item 'each'
    if ($each -and $each -ge 40 -and $g -ge ($each * 0.6)) { $n = [Math]::Round($g / $each, 1); if ([Math]::Abs($n - [Math]::Round($n)) -lt 0.25) { $n = [Math]::Round($n) }; return ("$n " + (Get-FaEachNoun $item $n)) }
    if ($item -match $script:FA_WEIGHT_FIRST -or $item -match $script:FA_WEIGHT_MEAT) {
        if ($g -ge $script:FA_LB) { return ((Get-FaFrac ($g / $script:FA_LB)) + ' lb') }
        return ((Get-FaFrac ($g / $script:FA_OZ)) + ' oz')
    }
    $tb = Get-FaDen $item 'tbsp'
    if ($tb -and $g -lt 120) { return ((Get-FaFrac ($g / $tb)) + ' tbsp') }
    $cup = Get-FaDen $item 'cup'
    if ($cup) { return ((Get-FaFrac ($g / $cup)) + ' cups') }
    return ((Get-FaFrac ($g / $script:FA_OZ)) + ' oz')
}

function Test-FriendlyAmtAgainstCatalog {
    <#
      THE PORT'S ONLY DEFENCE. This library is a copy of logic that still lives inline in
      build-v2-spec.ps1, and a copy that nobody checks is a copy that drifts. So: take the catalog rows
      whose label ALREADY agrees with its grams - those are the builder's own undisturbed output - push
      the grams back through this function, and require the string to come out identical.

      It deliberately reads db\recipes rather than a fixture. A fixture would prove this file agrees with
      itself; only the live catalog proves it agrees with the builder that wrote the live catalog.

      THE MEASURE IS COVERAGE, NOT SELF-AGREEMENT. Deriving a label and then asking whether it equals
      itself proves nothing - the first version of this function did exactly that and would have passed
      with the arithmetic inverted. What carries signal is how many STORED labels this function reproduces
      byte for byte: the builder wrote them, so a faithful port reproduces thousands and a broken port
      reproduces almost none. Returns @{ rows; exact; pct } and the caller asserts a floor.
    #>
    param([string]$Root)
    $mp = if ($Root) { $Root } else { Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
    $rows = 0; $exact = 0
    foreach ($f in @(Get-ChildItem (Join-Path $mp 'db\recipes\*.json') | Where-Object { $_.Name -ne '_index.json' })) {
        $s = Get-Content $f.FullName -Raw | ConvertFrom-Json
        if (-not $s.scaler.ing) { continue }
        foreach ($i in @($s.scaler.ing)) {
            $buy = [string]$i.buy; $g = [double]$i.grams; $item = [string]$i.item
            if ($g -le 0 -or -not $buy) { continue }
            $derived = $null
            try { $derived = Get-FriendlyAmt $item $g -Faithful } catch { continue }   # no each-noun: not this test's business
            if (-not $derived) { continue }
            $rows++
            if ($buy -eq $derived) { $exact++ }
        }
    }
    return @{ rows = $rows; exact = $exact; pct = $(if ($rows) { [math]::Round(100.0 * $exact / $rows, 1) } else { 0 }) }
}
