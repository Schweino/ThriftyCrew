<#
  test-match-lib.ps1 - proves match-lib decides EXACTLY as the original Match-Category, on the real corpus.

  THE CONTRACT. match-lib exists for speed (see its header: 139 of 159 seconds per board build was the
  matcher). Speed bought by a second implementation is worthless the moment the two implementations
  disagree, because which product owns a cell IS the board's correctness. So this does not test
  match-lib against a description of the rule - it runs the ORIGINAL function, extracted verbatim from
  compare-deals.ps1 at test time, side by side with the new one, over every distinct product name the
  engine currently feeds the matcher, and demands the same answer for all of them.

  "Extracted at test time" is the point: if someone edits Match-Category in compare-deals and forgets
  match-lib (or the reverse), this goes red on the next suite run rather than the two drifting for a
  quarter. That is the `two copies of a rule` discipline applied to the one copy that was made on
  purpose.

  THE CORPUS IS NOT NEGOTIABLE. It is every distinct name, and it stays that way. The day the two
  implementations disagree it will be on some odd name - a size suffix, an ampersand, an empty string -
  which is exactly the name a sampled corpus drops. When this file got too slow (2026-08-23: 174 of
  test-auditors' 467 seconds) the answer was to split the WORK, never to shrink the corpus.

  *** AND THE SPLIT HAS TO BE PROCESSES, NOT RUNSPACES. *** Measured 2026-08-23, 3,000 names, the
  original Match-Category pass, run in an in-process runspace pool:
        1 runspace    8.9s CPU      2 runspaces   19.3s      4 runspaces   38.9s
        8 runspaces  79.5s CPU     16 runspaces  215.5s
  Wall clock sat at ~14s for every one of them. That is not sublinear scaling, it is NEGATIVE: the work
  is fully serialised and each extra thread only adds contention. The cause is that the original rule is
  written with PowerShell's `-match` and `-replace` operators, which call the STATIC Regex methods, and
  in .NET Framework every static Regex call goes through one process-wide pattern cache behind one lock.
  Sixteen threads in one process therefore queue on that lock forever. Sixteen PROCESSES each have their
  own cache and their own lock, and actually run at once. Anyone tempted to "simplify" this back to a
  runspace pool should re-measure first; the numbers above are what that costs.

  Exit 0 = identical on every name. Exit 1 = any divergence (listed). Exit 3 = could not extract the
  original, or a shard could not be run (then nothing is proven and the caller must treat match-lib as
  unverified - a corpus that quietly got smaller is the failure mode this whole file exists against).
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$Quiet, [int]$MaxNames = 0, [int]$Workers = 0,
      # SHARD MODE - set by the parent on its own children, never by a human. The parent hands over the
      # exact name list it built (so a shard can never be measuring a different corpus than its siblings),
      # the shard takes every ChunkOf'th name from ChunkIx, and writes its verdicts to OutFile as JSON.
      [string]$ChunkFile = '', [int]$ChunkOf = 0, [int]$ChunkIx = -1, [string]$OutFile = '')
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')
$isShard = [bool]$ChunkFile

# ---- 1. the ORIGINAL, verbatim, from compare-deals.ps1 -------------------------------------------
# THE START ANCHOR MOVED WITH THE LIST (2026-09-09, backlog I82). The exclude list used to be an array
# literal opening this very block, so `$GLOBAL_EXCLUDE = @(` marked where the extraction began; it is a
# library now and the engine's first line about it is the CALL. The library is dot-sourced here rather
# than lifted, because the extracted block below is run through [scriptblock]::Create, where $PSScriptRoot
# is empty and the engine's own dot-source line could not resolve.
$gexLibPath = Join-Path $root 'global-exclude-lib.ps1'
if (-not (Test-Path $gexLibPath)) {
  Write-Output 'match-lib: BLIND - global-exclude-lib.ps1 is missing, so the original matcher cannot be reconstructed; nothing proven'
  if (-not $isShard) { Write-GuardComplete -Name 'match-lib' -Summary 'BLIND: exclude library missing' }
  exit 3
}
. $gexLibPath
$src = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
# THE NEWLINE IN THE ANCHOR IS LOAD-BEARING. The engine's self-test block ALSO calls Get-TcGlobalExclude,
# indented, six hundred lines earlier, so a bare IndexOf finds that one first and the extraction starts in
# the middle of a brace block: PowerShell then fails to parse it with "Unexpected token '}'". Anchoring on
# a newline pins the extraction to the column-0 assignment, which is the one that opens the matcher.
$a = $src.IndexOf("`n" + '$GLOBAL_EXCLUDE = Get-TcGlobalExclude')
if ($a -ge 0) { $a = $a + 1 }
$b = $src.IndexOf('# ---------------------------------------------------------------- -Explain')
if ($a -lt 0 -or $b -lt 0 -or $b -le $a) {
  Write-Output 'match-lib: BLIND - could not locate GLOBAL_EXCLUDE..Match-Category in compare-deals.ps1; nothing proven'
  if (-not $isShard) { Write-GuardComplete -Name 'match-lib' -Summary 'BLIND: extraction failed' }
  exit 3
}
$block = $src.Substring($a, $b - $a)
$block = ($block -split "`n" | Where-Object { $_ -notmatch '\$GEX_OVERRIDE' }) -join "`n"
# THE REFERENCE CALLS ITS OWN Get-MatchTexts, NOT WHICHEVER ONE IS CURRENT (2026-09-18, backlog I184).
# PowerShell resolves a function NAME when the call runs, not where the caller was written. match-lib, loaded
# below, defines Get-MatchTexts again, so until this rename the extracted Match-Category called match-lib's copy
# on every corpus name: the corpus passes compared match-lib's normalisation with ITSELF, and only the one-name
# check under section 2 ever ran compare-deals' own. A divergence on any name that one did not exercise ('&' in
# place of 'and', say) went green over all 42,761 names. Renaming the lifted definition and its call site gives
# the reference a name nothing else defines. (The engine itself is not affected: its only Match-Category calls,
# the routing fixtures and -Explain, both run before its own `. match-lib.ps1` line.)
$refTextsName = 'Get-MatchTextsReference'
$refTextsRx = '(?<![\w-])Get-MatchTexts(?![\w-])'
if (([regex]::Matches($block, $refTextsRx)).Count -lt 2) {
  Write-Output 'match-lib: BLIND - the extracted block no longer defines AND calls Get-MatchTexts, so the reference cannot be insulated from match-lib; nothing proven'
  if (-not $isShard) { Write-GuardComplete -Name 'match-lib' -Summary 'BLIND: reference texts not found' }
  exit 3
}
$block = [regex]::Replace($block, $refTextsRx, $refTextsName)
# LIVE-TWIN on purpose (ops\audit-fixture-inputs.ps1, 2026-09-11): both matchers are handed this one copy of today's
# rules, and the contract is that they decide identically on them.
$commodities = Read-JsonFile (Join-Path $root 'commodities.json')
. ([scriptblock]::Create($block))      # defines $GLOBAL_EXCLUDE, Get-MatchTextsReference, Match-Category (original)
$origMatch = ${function:Match-Category}
$origTexts = ${function:Get-MatchTextsReference}

# ---- 2. the NEW one --------------------------------------------------------------------------------
. (Join-Path $root 'match-lib.ps1')    # redefines Get-MatchTexts identically; adds New-CommodityMatcher/Resolve-Commodity
$matcher = New-CommodityMatcher -Commodities $commodities -GlobalExclude $GLOBAL_EXCLUDE

# Get-MatchTexts must be byte-identical too, or the include texts differ before any regex runs.
$t1 = & $origTexts 'Member''s Mark Boneless and Skinless Chicken Breast, priced per pound'
$t2 = Get-MatchTexts 'Member''s Mark Boneless and Skinless Chicken Breast, priced per pound'
if (($t1 -join '|') -ne ($t2 -join '|')) { Write-Output "FAIL  Get-MatchTexts diverged: '$($t1 -join '|')' vs '$($t2 -join '|')'"; if (-not $isShard) { Write-GuardComplete -Name 'match-lib' -Summary 'failed=1 (texts)' }; exit 1 }

# MUST FIRE (I184): the reference must be INSULATED from the Get-MatchTexts that is current. Poison the current
# one (match-lib's) and the original's answer on a name it matches must not move. Before the rename above it
# moved - chicken-breast to <none> - because the reference was calling match-lib's copy. Asserted on the
# mechanism, every run, so a future edit that re-couples the two goes red here and not only on a lucky corpus name.
$insName = 'Member''s Mark Boneless and Skinless Chicken Breast, priced per pound'
$insBefore = & $origMatch $insName
$libTexts = ${function:Get-MatchTexts}
function Get-MatchTexts([string]$name) { return ,@('i184-poison', 'i184-poison') }
$insPoisoned = & $origMatch $insName
${function:Get-MatchTexts} = $libTexts
$insRestored = ((Get-MatchTexts $insName)[0] -ne 'i184-poison')
$insB = $(if ($insBefore) { [string]$insBefore.id } else { '' })
$insP = $(if ($insPoisoned) { [string]$insPoisoned.id } else { '' })
if (-not $insB -or -not $insRestored -or -not [string]::Equals($insB, $insP, [StringComparison]::Ordinal)) {
  Write-Output ("FAIL  reference not insulated from match-lib's Get-MatchTexts: original='{0}' with it poisoned='{1}' (restored={2}) - the corpus passes would compare match-lib with itself" -f $insB, $insP, $insRestored)
  if (-not $isShard) { Write-GuardComplete -Name 'match-lib' -Summary 'failed=1 (reference not insulated)' }
  exit 1
}

# ---- 2b. ROUTING FIXTURES on today's rules (2026-09-19, design\PLAN-board-accuracy-2026-09-19.md 4f) ------------
# The corpus passes below prove the two matchers AGREE; they cannot say either one is RIGHT. These cases pin the
# answer itself for the identity defects a blind verification found on the store's own pages that day, each run
# through match-lib over the live commodities.json and global excludes, so a later rule edit that re-opens one
# goes red here by name. Parent only: a shard is handed names, not cases.
if (-not $isShard) {
  $rtBad = 0; $rtRan = 0
  function _RT([string]$label, [string]$name, [string]$want) {
    $script:rtRan++
    $c = Resolve-Commodity -Matcher $matcher -Name $name
    $got = $(if ($c) { [string]$c.id } else { '<none>' })
    if (-not [string]::Equals($got, $want, [StringComparison]::Ordinal)) { Write-Output ("  FAIL  {0}   '{1}' routed to {2}, want {3}" -f $label, $name, $got, $want); $script:rtBad++ }
  }
  # MUST FIRE - the founding names, each verified on the store's page on 2026-09-19.
  _RT 'MUST FIRE  D1 an Aldi aioli leaves the fresh green-chilli cell (condiment_carrier class)' 'Burman S Green Chili Squeeze Aioli 10 OZ' '<none>'
  # D4 (2026-09-19 verification): Fareway's canned "La Choy Bean Sprouts" held the FRESH cell; its name never says canned
  # and Fareway rows carry no department. Every La Choy product in the captures is shelf-stable, so the brand is fenced.
  _RT 'MUST FIRE  D4 Fareway''s canned La Choy sprouts leave the FRESH bean-sprouts cell' 'La Choy Bean Sprouts' '<none>'
  _RT 'MUST FIRE  D2 an Aldi half & half named "creamer" prices half-and-half, not coffee-creamer' 'Friendly Farms Half & Half Creamer' 'half-and-half'
  _RT 'MUST FIRE  D2 a half & half single named "coffee creamer" prices half-and-half' 'Nestle Carnation Half & Half Creamers, Half and Half Coffee Creamer Singles, 360 Ct' 'half-and-half'
  _RT 'MUST FIRE  D2 a half and half single named "coffee" leaves the coffee cell' '0.38 oz. Coffee House Inspirations Half and Half (180/Carton)' 'half-and-half'
  _RT 'MUST FIRE  D3 the Baker''s coconut aminos "Seasoning Sauce" is no longer hidden by the global sauce token' 'Simple Truth Organic Coconut Aminos All-Purpose Seasoning Sauce' 'coconut-aminos'
  _RT 'MUST FIRE  D3 a coconut aminos "Soy Sauce Replacement" leaves the soy-sauce cell' 'BetterBody Foods Organic Coconut Aminos Soy Sauce Replacement, 16.9 fl oz' 'coconut-aminos'
  _RT 'MUST FIRE  D4 the Sam''s individually wrapped sponges are no longer hidden by the global wrapped token' 'Scotch-Brite Heavy Duty Scrub Sponges, Individually Wrapped 24 ct.' 'sponges'
  # teriyaki-sauce sits earlier in the file and wins this name either way, so the route alone cannot see the
  # coconut-aminos fence: the detail scan's contested set can, because it lists every commodity that also wanted it.
  $script:rtRan++
  $tdet = Resolve-CommodityDetail -Matcher $matcher -Name 'Coconut Aminos Teriyaki Sauce 10 fl oz'
  $tid = $(if ($tdet.commodity) { [string]$tdet.commodity.id } else { '<none>' })
  if ($tid -ne 'teriyaki-sauce' -or @($tdet.candidates) -contains 'coconut-aminos') { Write-Output ("  FAIL  MUST FIRE  D3 the teriyaki fence still holds after coconut-aminos relaxes sauce   got {0}, contested by {1}" -f $tid, (@($tdet.candidates) -join ',')); $rtBad++ }
  # MUST FIRE on the MECHANISM: the class reaches every produce commodity outside its exempt, so the next fresh
  # commodity is born fenced. An aggregate route count could not see one commodity quietly missing it.
  $ceLib = Read-JsonFile (Join-Path $root 'category-excludes.json')
  $ceCls = @($ceLib.classes.condiment_carrier)
  $ceEx = [string]$ceLib.exempt.condiment_carrier
  $produce = @(); foreach ($cc in (Read-JsonFile (Join-Path $root 'categories.json')).categories) { if ([string]$cc.label -match '^(Fruit|Vegetables)$') { $produce += @($cc.commodities) } }
  $cmById = @{}; foreach ($cm in $commodities) { $cmById[[string]$cm.id] = $cm }
  $reach = 0; $want = 0; $missing = @()
  foreach ($pid_ in $produce) {
    if ($ceEx -and ([string]$pid_ -match $ceEx)) { continue }
    $want++
    $ex = @($cmById[[string]$pid_].exclude)
    if (@($ceCls | Where-Object { $ex -notcontains $_ }).Count -eq 0) { $reach++ } else { $missing += [string]$pid_ }
  }
  $script:rtRan++
  if ($ceCls.Count -lt 6 -or $want -eq 0 -or $reach -ne $want) { Write-Output ("  FAIL  MUST FIRE  condiment_carrier reaches {0} of {1} non-exempt produce commodities ({2} patterns); missing: {3}" -f $reach, $want, $ceCls.Count, ($missing -join ',')); $rtBad++ }
  # MUST NOT FIRE - legal inputs the new fences and relaxes must leave where they are.
  _RT 'MUST NOT FIRE  a fresh green chili still prices green-chilli' 'Fresh Green Chili Peppers, per lb' 'green-chilli'
  _RT 'MUST NOT FIRE  plain half & half still prices half-and-half' 'Great Value Half & Half, 32 fl oz' 'half-and-half'
  _RT 'MUST NOT FIRE  a real soy sauce still prices soy-sauce' 'Kikkoman Traditionally Brewed Soy Sauce, 64 oz.' 'soy-sauce'
  _RT 'MUST NOT FIRE  fresh avocados still price avocados' 'Fresh Large Hass Avocado Bag, 3-4 Count' 'avocados'
  _RT 'MUST NOT FIRE  the exempt lemongrass-paste keeps its squeeze paste' 'Gourmet Garden Lemongrass Stir-In Paste, 4.0 oz' 'lemongrass-paste'
  # CLEAN TWIN - the neighbours each fix was most likely to break on its way past.
  _RT 'CLEAN TWIN  a flavoured coffee creamer still prices coffee-creamer' 'Nestle Coffee mate Liquid Non-Dairy Refrigerated Coffee Creamer, French Vanilla, 66 fl. oz' 'coffee-creamer'
  _RT 'CLEAN TWIN  real mayonnaise still prices mayonnaise' 'Kraft Real Mayo Mayonnaise, 30 fl. oz. jars, 2 pk.' 'mayonnaise'
  _RT 'CLEAN TWIN  canned diced green chiles still price canned-green-chilies' '(2 pack) Ortega Mild Fire Roasted Diced Green Chiles, Kosher, 7 oz Can' 'canned-green-chilies'
  _RT 'CLEAN TWIN  unwrapped sponges still price sponges' 'Scotch-Brite Heavy Duty Scrub Sponges' 'sponges'
  _RT 'CLEAN TWIN  plain coconut aminos still price coconut-aminos' 'Big Tree Farms Organic Coconut Aminos Original, 10 oz Bottle' 'coconut-aminos'
  # BRAD'S RULING 2026-09-19 "Fix all produce": the condiment class must hold on a produce commodity other than the
  # founding green-chilli. Garlic is the widest include in Vegetables (a bare \bgarlic\b), so a flavoured mayo or aioli
  # named for it is the likeliest next winner. No garlic mayo or aioli was in any capture that day, so these two names
  # are written for the case; both routed to garlic before condiment_carrier was baked in (checked against the rules
  # with the class's 681 baked patterns removed). The CLEAN TWINS are real shelf names from the 2026-09-17 board.
  _RT 'MUST FIRE  a roasted garlic mayo leaves the fresh garlic cell and prices mayonnaise' 'Kraft Roasted Garlic Mayo Mayonnaise, 12 fl oz' 'mayonnaise'
  _RT 'MUST FIRE  a garlic aioli mayo leaves the fresh garlic cell' 'Primal Kitchen Garlic Aioli Mayo, 12 oz' '<none>'
  _RT 'CLEAN TWIN  a fresh garlic bulb still prices garlic' 'Kroger Whole Garlic Bulbs' 'garlic'
  _RT 'CLEAN TWIN  fresh jalapenos still price jalapenos' 'Fresh Jalapeno Peppers' 'jalapenos'
  _RT 'CLEAN TWIN  fresh basil still prices fresh-basil' 'Gotham Greens Fresh Basil' 'fresh-basil'
  _RT 'CLEAN TWIN  fresh green chiles still price green-chilli' 'Fresh Green Chiles, per lb' 'green-chilli'
  # BRAD'S RULING 2026-09-19 "Fence stews and cans off produce". Walmart's canned Stokes stew was the cheapest
  # green-chilli cell on the 2026-09-17 board: the fresh fence had \bcanned\b but not the word Can, and soup_carrier
  # named soup, chowder, bisque and gumbo but not stew. soup_carrier gains \bstews?\b (produce and Meat, where it moves
  # only stews), and the can word is its own class, canned_carrier, scoped to Fruit and Vegetables ONLY: in soup_carrier
  # it would also reach Meat, where canned-tuna, canned-chicken and canned-salmon price real cans (measured over 77,482
  # names that day: 198 moved with it in soup_carrier, 70 with it produce-only, every one of the 70 a non-fresh product).
  _RT 'MUST FIRE  the Walmart canned green chile stew leaves the fresh green-chilli cell' 'Stokes Green Chile Stew with Pork and Potatoes, Medium, 15 oz Can' '<none>'
  _RT 'MUST FIRE  a canned carrot named only by the word Can leaves the fresh carrots cell' 'Great Value Sliced Carrots, 14.5 oz Can' '<none>'
  _RT 'MUST FIRE  canned peas and carrots do not re-land on canned-peas once they leave carrots' 'Kroger Sweet Peas & Carrots - 15oz can' '<none>'
  # MUST FIRE on the MECHANISM, as for condiment_carrier above: both new tokens reach every produce commodity.
  $script:rtRan++
  $stewRx = '\bstews?\b'
  $canCls = @($ceLib.classes.canned_carrier)
  $canMiss = @()
  foreach ($pid_ in $produce) {
    $ex = @($cmById[[string]$pid_].exclude)
    if (($ex -notcontains $stewRx) -or @($canCls | Where-Object { $ex -notcontains $_ }).Count -gt 0) { $canMiss += [string]$pid_ }
  }
  if (@($ceLib.classes.soup_carrier) -notcontains $stewRx -or $canCls -notcontains '\bcans?\b' -or $produce.Count -eq 0 -or $canMiss.Count -gt 0) { Write-Output ("  FAIL  MUST FIRE  stew and can reach {0} of {1} produce commodities; missing: {2}" -f ($produce.Count - $canMiss.Count), $produce.Count, ($canMiss -join ',')); $rtBad++ }
  _RT 'MUST NOT FIRE  a cantaloupe (the letters c-a-n, not the word) still prices cantaloupe' 'Large Cantaloupe, 1 ct.' 'cantaloupe'
  _RT 'MUST NOT FIRE  Mexican papayas (the letters c-a-n inside a word) still price papaya' 'Mexican Papayas' 'papaya'
  _RT 'CLEAN TWIN  a can of tuna still prices canned-tuna (the can word never reached Meat)' 'StarKist Chunk Light Tuna in Water Can' 'canned-tuna'
  _RT 'CLEAN TWIN  a can of mixed nuts with pecans still prices mixed-nuts (the can word never left produce)' 'Planters Lightly Salted Deluxe Mixed Nuts with Cashews, Almonds, Brazil Nuts, Pistachios, Pecans. 5g Protein (6% DV) per serving, 15.25 oz Can' 'mixed-nuts'
  _RT 'CLEAN TWIN  a canned garlic tomato paste leaves garlic for tomato-paste, not dried-oregano' 'Hunts Tomato Paste with Basil, Garlic and Oregano, Perfect for Chili & Soups, 6 oz. Can' 'tomato-paste'
  $rtWant = 35   # 19 from the 4f rules change, +1 for D4 (La Choy canned sprouts), +6 for the all-produce ruling, +9 for the stew/can ruling, 2026-09-19
  if ($rtRan -ne $rtWant) { Write-Output ("  FAIL  routing fixtures ran {0} case(s), the list holds {1}" -f $rtRan, $rtWant); $rtBad++ }
  if ($rtBad -gt 0) {
    Write-Output ("MATCH-LIB FAILED (routing fixtures: {0} of {1} failed)" -f $rtBad, $rtRan)
    Write-GuardComplete -Name 'match-lib' -Summary ("routing fixtures failed=" + $rtBad)
    exit 1
  }
  if (-not $Quiet) { Write-Output ("match-lib routing fixtures: {0} of {1} pass (condiment_carrier reaches {2} of {3} non-exempt produce commodities)" -f $rtRan, $rtWant, $reach, $want) }
}

# ---- 3. the corpus: every distinct name the engine feeds the matcher today -------------------------
# A SHARD DOES NOT REBUILD THE CORPUS, IT IS HANDED ONE. Rebuilding it per process would be both slower
# and unsound: the capture files underneath are live, so two shards started a second apart could enumerate
# different name sets and the union of their answers would silently cover neither corpus.
if ($isShard) {
  $list = @([string[]](Read-JsonFile $ChunkFile))
} else {
  . (Join-Path $root 'capture-depth-lib.ps1')
  . (Join-Path $root 'regular-fileset-lib.ps1')
  $names = @{}
  # LIVE-TWIN on purpose (ops\audit-fixture-inputs.ps1, 2026-09-11): THE CORPUS IS NOT NEGOTIABLE (header) - it is every
  # name the engine feeds the matcher today, so these reads are live by contract. The four below carry the same tag.
  $cmp = Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
  $today = if ($cmp -and $cmp.BaseName -match '(\d{4}-\d{2}-\d{2})$') { [datetime]$Matches[1] } else { Get-Date }
  foreach ($rf in (Select-RegularFileSet (Get-ChildItem (Join-Path $root 'out\regular\*-regular-*.json')) $today (Get-RegularUnionDays))) {   # LIVE-TWIN: the live corpus
    $ex = Read-JsonFile $rf.FullName
    foreach ($d in $ex.deals) { if ($d.item) { $names[[string]$d.item] = 1 } }
  }
  $adsF = Get-ChildItem (Join-Path $root 'out\ads-*.json') | Sort-Object Name -Descending | Select-Object -First 1   # LIVE-TWIN: the live corpus
  if ($adsF) { foreach ($d in (Read-JsonFile $adsF.FullName).deals) { if ($d.item) { $names[[string]$d.item] = 1 } } }
  foreach ($f in (Get-ChildItem (Join-Path $root 'out\sams\sams-deals-*.json') -EA SilentlyContinue)) { foreach ($d in (Read-JsonFile $f.FullName).deals) { if ($d.item) { $names[[string]$d.item] = 1 } } }   # LIVE-TWIN: the live corpus
  foreach ($sub in @('bakers\bakers-deals-*.json', 'fareway\fareway-deals-*.json')) {
    $f = Get-ChildItem (Join-Path $root ('out\' + $sub)) -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($f) { foreach ($d in (Read-JsonFile $f.FullName).deals) { if ($d.item) { $names[[string]$d.item] = 1 } } }
  }
  # Adversarial names the corpus may not contain today: the shapes that broke matchers before.
  foreach ($x in @('Hy-Vee butter, 16 oz., $2.48', 'GO2snax Mild Cheddar Cheese & Salami Tray', 'Marketside Tandoori Style Garlic Naan Bites',
                   'Wish-Bone Chunky Blue Cheese Salad Dressing', 'Red Apple Cheese Gruyere Cheese', 'mix & match bagels', 'Chunk Light Tuna in Water 5 oz',
                   'Simple Truth Protein Black Pepper Lentils Brown Rice and Quinoa Blend', 'Fresh Red Cherries, 2.25 lb Bag', '')) { $names[$x] = 1 }
  $list = @($names.Keys)
  if ($MaxNames -gt 0 -and $list.Count -gt $MaxNames) { $list = $list[0..($MaxNames - 1)] }
}

# ---- 3b. SHARD MODE: the four passes over my slice, then hand the verdicts back ---------------------
# Every comparison the single-threaded version made is made here, on a subset of the names: the original,
# the compiled path, the PowerShell fallback, and the detail scan. Matching a name is a pure function of
# (name, catalog) - no shared state, no order dependence, no writes - so which shard evaluates a name
# cannot change its answer. Each verdict carries its GLOBAL index so the parent can restore the exact
# single-threaded reporting order.
if ($isShard) {
  $ix = New-Object System.Collections.Generic.List[int]
  for ($i = $ChunkIx; $i -lt $list.Count; $i += $ChunkOf) { $ix.Add($i) }
  $n = $ix.Count
  $orig = New-Object 'string[]' $n; $new = New-Object 'string[]' $n; $newPs = New-Object 'string[]' $n
  $hasCore = ($null -ne $matcher.core)
  # BOTH paths are proven, separately. The compiled core is what production runs; the PowerShell path is
  # the fallback when Add-Type is unavailable. A harness that only tested "whichever loaded" would leave
  # one of them unverified, and the unverified one is exactly the one that runs on the day something is
  # different about the machine.
  $psOnly = [pscustomobject]@{ gex = $matcher.gex; entries = $matcher.entries; core = $null }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  for ($k = 0; $k -lt $n; $k++) { $c = & $origMatch $list[$ix[$k]]; $orig[$k] = $(if ($c) { [string]$c.id } else { '' }) }
  $tO = $sw.Elapsed.TotalSeconds; $sw.Restart()
  for ($k = 0; $k -lt $n; $k++) { $c = Resolve-Commodity -Matcher $matcher -Name $list[$ix[$k]]; $new[$k] = $(if ($c) { [string]$c.id } else { '' }) }
  $tN = $sw.Elapsed.TotalSeconds; $sw.Restart()
  for ($k = 0; $k -lt $n; $k++) { $c = Resolve-Commodity -Matcher $psOnly -Name $list[$ix[$k]]; $newPs[$k] = $(if ($c) { [string]$c.id } else { '' }) }
  $tP = $sw.Elapsed.TotalSeconds; $sw.Restart()
  # THE DETAIL SCAN MUST AGREE WITH THE ANSWER. Resolve-CommodityDetail is the second scan added for the
  # identity table (PLAN section 10.6): it does not stop at the first winner, so it can also report the
  # contested set. That makes it a THIRD copy of the one rule that decides which product owns a cell - and
  # this file's whole argument is that a second copy is only allowed to exist if it is proven against the
  # first on the real corpus, every suite run. So:
  #   * its winner must be the ORIGINAL Match-Category's answer, on every name;
  #   * a name it says is matched must NAME the include that fired - an empty include_hit would put a blank
  #     provenance line on a board cell, which is worse than none because it reads as "checked".
  $detailDiff = New-Object System.Collections.ArrayList
  $detailNoHit = New-Object System.Collections.ArrayList
  for ($k = 0; $k -lt $n; $k++) {
    $d = Resolve-CommodityDetail -Matcher $matcher -Name $list[$ix[$k]]
    $did = $(if ($d.commodity) { [string]$d.commodity.id } else { '' })
    if ($orig[$k] -ne $did) { [void]$detailDiff.Add([pscustomobject]@{ ix = $ix[$k]; name = $list[$ix[$k]]; original = $orig[$k]; detail = $did }) }
    elseif ($did -and -not $d.include_hit) { [void]$detailNoHit.Add([pscustomobject]@{ ix = $ix[$k]; name = $list[$ix[$k]] }) }
  }
  $tD = $sw.Elapsed.TotalSeconds
  # THE NORMALISATION ITSELF, ON EVERY NAME (I184). Get-MatchTexts' [1] is also the engine's name key, so two
  # copies that disagree on a name nobody's winner turns on are still two rules. Compared ordinally: a bare -ne
  # is culture-sensitive and ignores a NUL.
  $textDiff = New-Object System.Collections.ArrayList
  for ($k = 0; $k -lt $n; $k++) {
    $nm = $list[$ix[$k]]
    $tr = (& $origTexts $nm) -join [char]1
    $tl = (Get-MatchTexts $nm) -join [char]1
    if (-not [string]::Equals($tr, $tl, [StringComparison]::Ordinal)) { [void]$textDiff.Add([pscustomobject]@{ ix = $ix[$k]; name = $nm; original = ($tr -replace [char]1, ' | '); lib = ($tl -replace [char]1, ' | ') }) }
  }
  # COULD-NOT-LOOK ON THE REAL CORPUS (2026-09-19, I183/I209). match-lib now bounds every regex at 250 ms and
  # scores a timed-out name could-not-look, which reads as "" here exactly like an unmatched name - so a blind
  # name would AGREE with an original that also found nothing and pass as proven. Counted and failed instead:
  # no real name has come near the bound (worst 15.1 ms over 42,753 names on 2026-09-19).
  $blindC = @((Get-CommodityMatcherBlind -Matcher $matcher).could_not_look).Count
  $blindP = @((Get-CommodityMatcherBlind -Matcher $psOnly).could_not_look).Count
  # key = ix*2 (+1 for the fallback entry) reproduces the single-threaded emission order exactly: one pass
  # over the names, and for each name the fast-path divergence before the powershell-fallback one.
  $diff = New-Object System.Collections.ArrayList
  $matched = 0
  for ($k = 0; $k -lt $n; $k++) {
    if ($orig[$k]) { $matched++ }
    if ($orig[$k] -ne $new[$k])   { [void]$diff.Add([pscustomobject]@{ key = ($ix[$k] * 2);     name = $list[$ix[$k]]; original = $orig[$k]; fast = $new[$k];   path = $(if ($hasCore) { 'compiled' } else { 'powershell' }) }) }
    if ($orig[$k] -ne $newPs[$k]) { [void]$diff.Add([pscustomobject]@{ key = ($ix[$k] * 2 + 1); name = $list[$ix[$k]]; original = $orig[$k]; fast = $newPs[$k]; path = 'powershell-fallback' }) }
  }
  ([pscustomobject]@{
    names = $n; core = $hasCore; matched = $matched; blind = ($blindC + $blindP); diff = @($diff.ToArray()); detailDiff = @($detailDiff.ToArray())
    detailNoHit = @($detailNoHit.ToArray()); textDiff = @($textDiff.ToArray()); tO = $tO; tN = $tN; tP = $tP; tD = $tD
  } | ConvertTo-Json -Depth 6 -Compress) | Set-Content -LiteralPath $OutFile -Encoding UTF8
  exit 0
}

# ---- 4. PARENT: run the shards, then merge their verdicts -------------------------------------------
# The children are ordinary powershell children, spawned through native-lib's Invoke-NativeScript exactly
# like every other child in this estate - the redirect happens inside a call that has forced EAP to
# 'Continue', so a shard writing to stderr cannot terminate this script. The runspace pool here is only a
# way to have several of those calls in flight at once; no matching happens on these threads, which is
# the entire point (see the header).
. (Join-Path $root 'native-lib.ps1')
$hasCore = ($null -ne $matcher.core)
$W = $Workers
if ($W -le 0) { $W = [Math]::Min(16, [Math]::Max(1, [Environment]::ProcessorCount - 2)) }
if ($W -gt $list.Count) { $W = [Math]::Max(1, $list.Count) }
$shardDir = Join-Path $env:TEMP ('matchlib-shard-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $shardDir -Force
$corpusFile = Join-Path $shardDir 'corpus.json'
(ConvertTo-Json @($list) -Compress) | Set-Content -LiteralPath $corpusFile -Encoding UTF8

# The shard runs THIS file, by the path this file was actually invoked as - never a path rebuilt from
# $root. A copy of this harness under another name (which is how the parallel rewrite was proved against
# the single-threaded one) must shard ITSELF, not whatever test-match-lib.ps1 happens to be next to it.
$selfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$shardSb = {
  param([string]$Lib, [string]$Path, [object[]]$Argv)
  $ErrorActionPreference = 'Continue'
  . $Lib
  $r = Invoke-NativeScript $Path @Argv
  [pscustomobject]@{ rc = $r.ExitCode; text = ((@($r.Lines) | ForEach-Object { [string]$_ }) -join "`n") }
}
$swAll = [Diagnostics.Stopwatch]::StartNew()
$pool = [runspacefactory]::CreateRunspacePool(1, $W)
$pool.Open()
$jobs = @()
for ($k = 0; $k -lt $W; $k++) {
  $of = Join-Path $shardDir ("shard-$k.json")
  $ps = [powershell]::Create()
  $ps.RunspacePool = $pool
  [void]$ps.AddScript([string]$shardSb).AddArgument((Join-Path $root 'native-lib.ps1')).AddArgument($selfPath).AddArgument(
    [object[]]@('-ChunkFile', $corpusFile, '-ChunkOf', $W, '-ChunkIx', $k, '-OutFile', $of))
  $jobs += [pscustomobject]@{ ps = $ps; handle = $ps.BeginInvoke(); out = $of; ix = $k }
}
$results = @()
$shardErr = $null
foreach ($j in $jobs) {
  $res = $null
  try { $res = @($j.ps.EndInvoke($j.handle))[0] } catch { $res = [pscustomobject]@{ rc = -1; text = $_.Exception.Message } }
  $j.ps.Dispose()
  if ($null -eq $shardErr) {
    if ($null -eq $res -or $res.rc -ne 0) { $shardErr = ("shard {0} exited {1}: {2}" -f $j.ix, $(if ($res) { $res.rc } else { -1 }), $(if ($res) { $res.text } else { '' })) }
    elseif (-not (Test-Path $j.out)) { $shardErr = ("shard {0} exited 0 but wrote no verdicts" -f $j.ix) }
    else { $results += (Read-JsonFile $j.out) }
  }
}
$pool.Close(); $pool.Dispose()
Remove-Item $shardDir -Recurse -Force -ErrorAction SilentlyContinue
$tWall = $swAll.Elapsed.TotalSeconds

# A SHARD THAT DIED PROVES NOTHING, and must never be able to shrink the corpus quietly - the union of
# the survivors' answers would read as a clean run over a corpus nobody chose. Same verdict as a failed
# extraction: exit 3, and the caller treats match-lib as unverified.
if ($null -ne $shardErr) {
  Write-Output ('match-lib: BLIND - part of the corpus was never compared: ' + $shardErr)
  Exit-Guard -Name 'match-lib' -Summary 'BLIND: shard failed' -Code 3
}
$seen = 0; foreach ($r in $results) { $seen += [int]$r.names }
if ($seen -ne $list.Count) {
  Write-Output ('match-lib: BLIND - the shards between them compared {0} of {1} names' -f $seen, $list.Count)
  Exit-Guard -Name 'match-lib' -Summary 'BLIND: corpus not covered' -Code 3
}
# EVERY SHARD MUST HAVE HAD THE SAME MATCHER AS THIS PROCESS. If one of them failed to Add-Type, its
# "compiled" pass was actually the interpreted one: the run would still go green while leaving the path
# production uses unproven, and any divergence it did find would be filed against the wrong path.
$badCore = @($results | Where-Object { [bool]$_.core -ne $hasCore })
if ($badCore.Count) {
  Write-Output ('match-lib: BLIND - {0} of {1} shards disagreed with this process about the compiled core (hasCore={2})' -f $badCore.Count, $results.Count, $hasCore)
  Exit-Guard -Name 'match-lib' -Summary 'BLIND: shard core mismatch' -Code 3
}
# The four phase timings are the SUM of the shards' own stopwatches - the same CPU seconds the
# single-threaded version reported, so the speedup ratio below still compares the two matchers against
# each other and not against the core count. Wall clock is reported on its own line.
$tO = ($results | Measure-Object -Property tO -Sum).Sum
$tN = ($results | Measure-Object -Property tN -Sum).Sum
$tP = ($results | Measure-Object -Property tP -Sum).Sum
$tD = ($results | Measure-Object -Property tD -Sum).Sum
# Merged and re-sorted into the single-threaded order by the global name index, so every line printed
# below is the line the single-threaded version would have printed, in the order it would have printed it.
# (Gathered element by element rather than with a pipeline: ConvertFrom-Json can hand back $null for an
# empty list, and a $null flowing through ForEach-Object would be COUNTED as a divergence.)
function Gather($rs, $prop) {
  $acc = New-Object System.Collections.ArrayList
  foreach ($r in $rs) { foreach ($x in @($r.$prop)) { if ($null -ne $x) { [void]$acc.Add($x) } } }
  return @($acc.ToArray())
}
$detailDiff  = @(Gather $results 'detailDiff'  | Sort-Object ix)
$detailNoHit = @(Gather $results 'detailNoHit' | Sort-Object ix | ForEach-Object { $_.name })
$diff        = @(Gather $results 'diff'        | Sort-Object key)
$textDiff    = @(Gather $results 'textDiff'    | Sort-Object ix)
$matched     = 0; foreach ($r in $results) { $matched += [int]$r.matched }
$blindNames  = 0; foreach ($r in $results) { $blindNames += [int]$r.blind }

if (-not $Quiet) {
  Write-Output ("match-lib identity: {0} distinct names ({1} matched by the original)" -f $list.Count, $matched)
  Write-Output ("  original Match-Category : {0,7:N1}s" -f $tO)
  Write-Output ("  match-lib (compiled={2}) : {0,7:N1}s   ({1:N1}x faster)" -f $tN, $(if ($tN -gt 0) { $tO / $tN } else { 0 }), $hasCore)
  Write-Output ("  match-lib (ps fallback) : {0,7:N1}s   ({1:N1}x faster)" -f $tP, $(if ($tP -gt 0) { $tO / $tP } else { 0 }))
  Write-Output ("  detail scan (identity)  : {0,7:N1}s   ({1} winner divergence(s), {2} matched name(s) with no include_hit)" -f $tD, $detailDiff.Count, $detailNoHit.Count)
  Write-Output ("  shards                  : {0,7:N1}s wall across {1} process(es)" -f $tWall, $W)
  Write-Output ("  divergences             : {0}" -f $diff.Count)
  Write-Output ("  Get-MatchTexts          : {0} of {1} name(s) normalised differently by the reference and match-lib" -f $textDiff.Count, $list.Count)
  Write-Output ("  could-not-look          : {0} name look(s) hit the regex bound (compiled + fallback)" -f $blindNames)
  foreach ($d in ($diff | Select-Object -First 15)) { Write-Output ("     [{3}] '{0}'  original={1}  fast={2}" -f $d.name, $(if ($d.original) { $d.original } else { '<none>' }), $(if ($d.fast) { $d.fast } else { '<none>' }), $d.path) }
  foreach ($d in ($detailDiff | Select-Object -First 15)) { Write-Output ("     [detail] '{0}'  original={1}  detail={2}" -f $d.name, $(if ($d.original) { $d.original } else { '<none>' }), $(if ($d.detail) { $d.detail } else { '<none>' })) }
  foreach ($n in ($detailNoHit | Select-Object -First 10)) { Write-Output ("     [detail] '{0}' matched but named no include pattern" -f $n) }
  foreach ($d in ($textDiff | Select-Object -First 10)) { Write-Output ("     [texts] '{0}'  original='{1}'  match-lib='{2}'" -f $d.name, $d.original, $d.lib) }
}
if ($diff.Count -or $detailDiff.Count -or $detailNoHit.Count -or $blindNames -or $textDiff.Count) {
  $total = $diff.Count + $detailDiff.Count + $detailNoHit.Count + $blindNames + $textDiff.Count
  Write-Output ("MATCH-LIB FAILED ({0} divergence(s): {1} fast-path, {2} detail-winner, {3} detail-no-include-hit, {4} could-not-look, {5} Get-MatchTexts) - match-lib must not be used by the engine until it decides identically" -f $total, $diff.Count, $detailDiff.Count, $detailNoHit.Count, $blindNames, $textDiff.Count)
  Exit-Guard -Name 'match-lib' -Summary "names=$($list.Count) divergences=$total" -Code 1
}
Write-Output 'MATCH-LIB PASSED'
Exit-Guard -Name 'match-lib' -Summary ("names=" + $list.Count + " divergences=0 detail=0 speedup=" + [math]::Round($(if ($tN -gt 0) { $tO / $tN } else { 0 }), 1) + "x") -Code 0
