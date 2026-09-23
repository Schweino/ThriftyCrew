<#
  audit-ingredient-identity.ps1 - does every recipe ingredient's commodity id name the SAME FOOD the board prices?

  ONE CHECK, THREE CALLERS (2026-09-22, grocery/triage-plans/plan-2026-09-22-9.json,
  discovered:recipe-ingredient-identity-2026-09-22): run-gates runs -SelfTest at push, check-ad-cycles runs
  the data pass daily in its fan-out, and ingredient-resolutions.ps1 runs Test-ReuseIdentity (the same library)
  before it records a REUSE. The rules live in meal-prep/lib/ingredient-identity-lib.ps1.

  (a) each db\ingredients.json row with relation `same` and a weekly bid: its own name, routed through the LIVE
      commodity rules (grocery/match-lib.ps1 + Get-TcGlobalExclude), must land on its bid. PROXY when it lands
      on another commodity (Shallots bid onions routed to shallots), UNROUTED when it lands nowhere.
  (b) each `derived` row: buy_pkg_g == yield_g_per_parent_unit x parent_units_per_purchase (Orange Zest bought
      131 g of zest-grams, 6.30 lb of oranges, for one orange).
  (c) each costed line priced `board:<id>:<store>`: the product that prices it at that store on the newest board
      must name the ingredient's head word (a thigh line priced by "Tyson Fresh Chicken Drumstick").
  `substitute` is a finding by name: Brad ruled no substitute of any kind on 2026-09-22.

  RATCHET. Findings are KEYED, and the committed mark (ops/out/ingredient-identity-baseline.json) holds the keys
  of the day it landed. A key not in the mark is a RISE and exits 2, whatever the count does. A fall is spoken
  and the mark KEPT; -Tighten records it. A plain run never writes the mark.

  SCOPE OF A CLEAN REPORT: unsound. A pricing row that names the head word can still be the wrong member of a
  union (Cherry Tomatoes priced by Grape Tomato shares `tomato`), and a qualifier inside one class (pork vs beef
  chorizo) is invisible to a word test; the 75 rows on recipe-board-only ids get only check (b). A finding is a
  candidate to read, not a verdict: the head-word test is incomplete where a store's name omits the class word.

  Exit: 0 no rise (fall spoken), 2 a new finding key (a rise), 3 could not evaluate. Last line:
  INGREDIENT-IDENTITY-COMPLETE.
#>
[CmdletBinding()]
param(
  [switch]$SelfTest,
  [switch]$Tighten,
  [string]$RowsFile = '',
  [string]$CommoditiesFile = '',
  [string]$BoardFile = '',
  [string]$CostedFile = '',
  [string]$BaselineFile = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')
. (Join-Path $mp 'lib\ingredient-identity-lib.ps1')
# The matcher is dot-sourced at SCRIPT scope: a resolver closure cannot see functions dot-sourced inside a function.
. (Join-Path $repo 'grocery\match-lib.ps1')
. (Join-Path $repo 'grocery\global-exclude-lib.ps1')
if (-not $RowsFile)        { $RowsFile = Join-Path $mp 'db\ingredients.json' }
if (-not $CommoditiesFile) { $CommoditiesFile = Join-Path $repo 'grocery\commodities.json' }
if (-not $CostedFile)      { $CostedFile = Join-Path $mp 'db\costed.json' }
if (-not $BaselineFile)    { $BaselineFile = Join-Path $repo 'ops\out\ingredient-identity-baseline.json' }

function New-IdentityResolver {
  <# name -> commodity id or $null, over a commodity list, through the SAME matcher the board uses. #>
  param($Commodities, [string[]]$GlobalExclude)
  $m = New-CommodityMatcher -Commodities $Commodities -GlobalExclude $GlobalExclude
  return { param($n) $c = Resolve-Commodity -Matcher $m -Name ([string]$n); if ($c) { [string]$c.id } else { $null } }.GetNewClosure()
}

function Invoke-IdentityRun {
  <# The data pass. Returns [pscustomobject]@{ Code; Lines }. #>
  $lines = New-Object System.Collections.ArrayList
  try {
    $rows = Read-JsonFile $RowsFile
    $coms = Read-JsonFile $CommoditiesFile
    $gex = @(Get-TcGlobalExclude)
    $resolve = New-IdentityResolver -Commodities $coms -GlobalExclude $gex
    $weekly = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($c in @($coms)) { [void]$weekly.Add([string]$c.id) }
    $bf = $BoardFile
    if (-not $bf) {
      $g = Get-ChildItem (Join-Path $repo 'grocery\out\comparison-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
      if ($g) { $bf = $g.FullName }
    }
    if (-not $bf -or -not (Test-Path $bf)) { [void]$lines.Add('audit-ingredient-identity: COULD NOT EVALUATE - no comparison board to read (check c needs one)'); return [pscustomobject]@{ Code = 3; Lines = $lines } }
    if (-not (Test-Path $CostedFile)) { [void]$lines.Add('audit-ingredient-identity: COULD NOT EVALUATE - no costed.json at ' + $CostedFile); return [pscustomobject]@{ Code = 3; Lines = $lines } }
    $bix = Get-IdentityBoardIndex (Read-JsonFile $bf)
    $costed = Read-JsonFile $CostedFile
    $f = @(Get-IngredientIdentityFindings -Rows $rows -Resolve $resolve -WeeklyIds $weekly -BoardIndex $bix -Costed $costed)
  } catch {
    [void]$lines.Add('audit-ingredient-identity: COULD NOT EVALUATE - ' + $_.Exception.Message); return [pscustomobject]@{ Code = 3; Lines = $lines }
  }
  $keys = @($f | ForEach-Object { [string]$_.key } | Sort-Object -Unique)
  $kinds = @($f | Group-Object kind | Sort-Object Name | ForEach-Object { $_.Name + '=' + $_.Count }) -join ' '
  [void]$lines.Add(('audit-ingredient-identity: {0} vocabulary row(s), {1} costed recipe(s), board {2}: {3} finding(s) [{4}]' -f @($rows).Count, @($costed).Count, (Split-Path $bf -Leaf), $keys.Count, $kinds))
  $base = $null
  if (Test-Path $BaselineFile) { $base = Read-JsonFile $BaselineFile }
  if ($null -eq $base) {
    if ($Tighten) {
      $doc = [ordered]@{ recorded = (Get-Date -Format 'yyyy-MM-dd'); why = 'day-one mark of the ingredient identity check (plan-2026-09-22-9); may only fall'; count = $keys.Count; keys = @($keys) }
      [void](Write-TcLfFile -Path $BaselineFile -Text (([pscustomobject]$doc) | ConvertTo-Json -Depth 4) -NoBom)
      [void]$lines.Add('  mark RECORDED at ' + $keys.Count + ' finding key(s): ' + $BaselineFile)
      foreach ($x in $f) { [void]$lines.Add('  ' + $x.kind + '  ' + $x.detail) }
      return [pscustomobject]@{ Code = 0; Lines = $lines }
    }
    [void]$lines.Add('audit-ingredient-identity: COULD NOT EVALUATE - no committed mark at ' + $BaselineFile + ' (record one with -Tighten)')
    return [pscustomobject]@{ Code = 3; Lines = $lines }
  }
  $known = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($k in @($base.keys)) { [void]$known.Add([string]$k) }
  $new = @($f | Where-Object { -not $known.Contains([string]$_.key) })
  if ($new.Count -gt 0) {
    [void]$lines.Add(('  RISE: {0} finding(s) not in the mark of {1} (mark {2}):' -f $new.Count, [string]$base.recorded, [int]$base.count))
    foreach ($x in $new) { [void]$lines.Add('  NEW  ' + $x.kind + '  ' + $x.detail) }
    return [pscustomobject]@{ Code = 2; Lines = $lines }
  }
  if ($keys.Count -lt [int]$base.count) {
    if ($Tighten) {
      $doc = [ordered]@{ recorded = (Get-Date -Format 'yyyy-MM-dd'); why = [string]$base.why; count = $keys.Count; keys = @($keys) }
      [void](Write-TcLfFile -Path $BaselineFile -Text (([pscustomobject]$doc) | ConvertTo-Json -Depth 4) -NoBom)
      [void]$lines.Add(('  mark TIGHTENED {0} -> {1}' -f [int]$base.count, $keys.Count))
    } else {
      [void]$lines.Add(('  ratchet CAN tighten: {0} -> {1} (mark kept; -Tighten records it)' -f [int]$base.count, $keys.Count))
    }
  }
  foreach ($x in $f) { [void]$lines.Add('  ' + $x.kind + '  ' + $x.detail) }
  return [pscustomobject]@{ Code = 0; Lines = $lines }
}

# ---- SELF-TEST ------------------------------------------------------------------------------------------
if ($SelfTest) {
  $bad = 0; $ran = 0
  function Check([string]$n, [bool]$ok, [string]$got) { $script:ran++; if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ } }
  # FROZEN RULES: the four commodities of the founding rows, as the live file held them on 2026-09-22.
  $coms = @(
    [pscustomobject]@{ id = 'onions'; include = @('\bonions?\b'); exclude = @('shallots?\b', 'green\s+onions?') },
    [pscustomobject]@{ id = 'shallots'; include = @('shallots?\b'); exclude = @('fried', 'crispy') },
    [pscustomobject]@{ id = 'ground-pork'; include = @('ground\s+pork'); exclude = @('chorizo') },
    [pscustomobject]@{ id = 'mexican-chorizo-fresh'; include = @('^(?=.*\bchorizo\b)(?=.*\b(?:mexican(?:[-\s]+style)?|pork|beef|ground|sausage|cacique)\b).*$'); exclude = @('\bbeef\b') },
    [pscustomobject]@{ id = 'chicken-thighs'; include = @('chicken\s+(thigh|drumstick|leg)'); exclude = @() },
    [pscustomobject]@{ id = 'oranges'; include = @('\boranges?\b'); exclude = @('juice') },
    [pscustomobject]@{ id = 'lemons'; include = @('\blemons?\b'); exclude = @('juice') }
  )
  $resolve = New-IdentityResolver -Commodities $coms -GlobalExclude @('\bzz-fixture-never-matches\b')
  $weekly = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($c in $coms) { [void]$weekly.Add([string]$c.id) }
  function Rw([string]$item, [string]$bid, [hashtable]$more = @{}) { $h = [ordered]@{ item = $item; bid = $bid }; foreach ($k in $more.Keys) { $h[$k] = $more[$k] }; return [pscustomobject]$h }
  function KindsOf($rows, $bix = $null, $costed = $null) { $x = @(Get-IngredientIdentityFindings -Rows $rows -Resolve $resolve -WeeklyIds $weekly -BoardIndex $bix -Costed $costed); return ,@($x | ForEach-Object { [string]$_.kind }) }

  $k = KindsOf @(Rw 'Shallots' 'onions')
  Check 'MUST FIRE  Shallots bid onions (relation same) is a PROXY: its own name routes to shallots' ($k -contains 'PROXY') ($k -join ',')
  $k = KindsOf @(Rw 'Pork Chorizo' 'ground-pork')
  Check 'MUST FIRE  Pork Chorizo bid ground-pork is a PROXY: its own name routes to mexican-chorizo-fresh' ($k -contains 'PROXY') ($k -join ',')
  $k = KindsOf @(Rw 'Yellow Onion' 'onions')
  Check 'MUST NOT FIRE  Yellow Onion bid onions is the same food' ($k.Count -eq 0) ($k -join ',')
  $k = KindsOf @(Rw 'Shallots' 'shallots')
  Check 'CLEAN TWIN  the repaired Shallots bid shallots routes to its own bid and reads clean' ($k.Count -eq 0) ($k -join ',')
  $k = KindsOf @(Rw 'Tandoori Masala' 'onions' @{ relation = 'substitute' })
  Check 'MUST FIRE  a declared substitute is a finding by name (Brad, 2026-09-22: no substitute of any kind)' ($k -contains 'SUBSTITUTE') ($k -join ',')

  # (b) THE BAR IS EQUALITY: yield 6.0 g x 1 orange. 6 is AT the bar and clean; 6.5 (a half-gram step, binary-exact) is past it.
  $oz = @{ relation = 'derived'; parent_units_per_purchase = 1; yield_g_per_parent_unit = 6.0 }
  $k = KindsOf @(Rw 'Orange Zest' 'oranges' ($oz + @{ buy_pkg_g = 131 }))
  Check 'MUST FIRE  Orange Zest buy_pkg_g 131 against yield 6.0 g x 1 orange (the 6.3 lb of oranges) is a DERIVED-BASIS finding' ($k -contains 'DERIVED-BASIS') ($k -join ',')
  $k = KindsOf @(Rw 'Orange Zest' 'oranges' ($oz + @{ buy_pkg_g = 6 }))
  Check 'MUST NOT FIRE  AT THE BAR: buy_pkg_g exactly 6 == 6.0 x 1 is clean' ($k.Count -eq 0) ($k -join ',')
  $k = KindsOf @(Rw 'Orange Zest' 'oranges' ($oz + @{ buy_pkg_g = 6.5 }))
  Check 'MUST FIRE  ONE STEP PAST THE BAR: buy_pkg_g 6.5 against 6.0 is a finding' ($k -contains 'DERIVED-BASIS') ($k -join ',')
  $k = KindsOf @(Rw 'Fresh Lemon Juice' 'lemons' @{ relation = 'derived'; parent_units_per_purchase = 1; yield_g_per_parent_unit = 47; buy_pkg_g = 47 })
  Check 'CLEAN TWIN  Fresh Lemon Juice declared derived from lemons (47 g a lemon) stays clean, though its name would route elsewhere' ($k.Count -eq 0) ($k -join ',')
  $k = KindsOf @(Rw 'Lemon Zest' 'lemons' @{ relation = 'derived'; parent_units_per_purchase = 1; yield_g_per_parent_unit = 6; buy_pkg_g = 6 })
  Check 'CLEAN TWIN  Lemon Zest (buy_pkg_g 6 == 6 x 1 on an each fruit) stays clean' ($k.Count -eq 0) ($k -join ',')

  # (c) the union row: a thigh line priced by the drumstick bag that won chicken-thighs on 2026-09-22.
  $board = [pscustomobject]@{ comparison = @(
    [pscustomobject]@{ id = 'chicken-thighs'; cheapest_store = 'Walmart'; stores = @([pscustomobject]@{ store = 'Walmart'; item = 'Tyson Fresh Chicken Drumstick, 10 lb Bag' }, [pscustomobject]@{ store = "Sam's Club"; item = "Member's Mark Bone-In Chicken Thighs, priced per pound" }) },
    [pscustomobject]@{ id = 'oranges'; cheapest_store = 'Walmart'; stores = @([pscustomobject]@{ store = 'Walmart'; item = 'Navel Oranges, 8 lb Bag' }) },
    [pscustomobject]@{ id = 'onions'; cheapest_store = 'Walmart'; stores = @([pscustomobject]@{ store = 'Walmart'; item = 'Fresh Yellow Onions, 3 lb Bag' }) }) }
  $bix = Get-IdentityBoardIndex $board
  $cost = @([pscustomobject]@{ slug = 'fixture-thighs'; lines = @([pscustomobject]@{ item = 'Bone-In Skin-On Chicken Thighs'; basis = 'board:chicken-thighs:walmart' }) })
  $k = KindsOf @(Rw 'Bone-In Skin-On Chicken Thighs' 'chicken-thighs') $bix $cost
  Check 'MUST FIRE  a thigh line priced by "Tyson Fresh Chicken Drumstick, 10 lb Bag" is a UNION-ROW finding' ($k -contains 'UNION-ROW') ($k -join ',')
  $cost2 = @([pscustomobject]@{ slug = 'fixture-thighs'; lines = @([pscustomobject]@{ item = 'Bone-In Skin-On Chicken Thighs'; basis = "board:chicken-thighs:sam's club" }) })
  $k = KindsOf @(Rw 'Bone-In Skin-On Chicken Thighs' 'chicken-thighs') $bix $cost2
  Check "MUST NOT FIRE  the same line priced by Sam's bone-in thighs names its food" ($k.Count -eq 0) ($k -join ',')
  $cost3 = @([pscustomobject]@{ slug = 'fixture-zest'; lines = @([pscustomobject]@{ item = 'Orange Zest'; basis = 'board:oranges:walmart' }, [pscustomobject]@{ item = 'Yellow Onion'; basis = 'board:onions:walmart' }) })
  $k = KindsOf @((Rw 'Orange Zest' 'oranges' ($oz + @{ buy_pkg_g = 6 })), (Rw 'Yellow Onion' 'onions')) $bix $cost3
  Check 'CLEAN TWIN  a derived zest line is asked about its PARENT and "Navel Oranges" answers; Yellow Onion by yellow onions answers' ($k.Count -eq 0) ($k -join ',')

  # THE MAPPER'S WRITE: the standing REUSE bone-in skin-on chicken thighs -> chicken-thighs is refused while the
  # cell is won by a drumstick bag, and a term that routes elsewhere is refused outright.
  $why = Test-ReuseIdentity -Term 'bone-in skin-on chicken thighs' -Id 'chicken-thighs' -Resolve $resolve -WeeklyIds $weekly -BoardIndex $bix
  Check 'MUST FIRE  the mapper refuses the chicken-thighs REUSE while its crown is the drumstick bag' ([bool]$why) ([string]$why)
  $why = Test-ReuseIdentity -Term 'pork chorizo' -Id 'ground-pork' -Resolve $resolve -WeeklyIds $weekly -BoardIndex $bix
  Check 'MUST FIRE  the mapper refuses pork chorizo -> ground-pork (the chorizo-as-ground-pork line)' ([bool]$why) ([string]$why)
  $why = Test-ReuseIdentity -Term 'yellow onion' -Id 'onions' -Resolve $resolve -WeeklyIds $weekly -BoardIndex $bix
  Check 'CLEAN TWIN  the mapper still records yellow onion -> onions' ($null -eq $why) ([string]$why)
  Check 'CLEAN TWIN  Get-TokenStem folds the plural the vocabulary missed: shallots -> shallot, and keeps asparagus' (((Get-TokenStem 'shallots') -eq 'shallot') -and ((Get-TokenStem 'asparagus') -eq 'asparagus')) ((Get-TokenStem 'shallots') + '/' + (Get-TokenStem 'asparagus'))

  # THE RATCHET, run as a child over temp files: a fall keeps the mark byte-identical, -Tighten writes it,
  # and a new key is a RISE (exit 2).
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('iid-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  try {
    $enc = New-Object System.Text.UTF8Encoding($false)
    $cf = Join-Path $tmp 'c.json'; $rf = Join-Path $tmp 'r.json'; $bfile = Join-Path $tmp 'comparison-2026-09-22.json'; $kf = Join-Path $tmp 'k.json'; $mf = Join-Path $tmp 'mark.json'
    [IO.File]::WriteAllText($cf, (ConvertTo-Json -InputObject @($coms) -Depth 5), $enc)
    [IO.File]::WriteAllText($bfile, ($board | ConvertTo-Json -Depth 6), $enc)
    [IO.File]::WriteAllText($kf, '[]', $enc)
    [IO.File]::WriteAllText($rf, (ConvertTo-Json -InputObject @((Rw 'Shallots' 'onions'), (Rw 'Pork Chorizo' 'ground-pork')) -Depth 4), $enc)
    $a = @('-NoProfile', '-File', $PSCommandPath, '-RowsFile', $rf, '-CommoditiesFile', $cf, '-BoardFile', $bfile, '-CostedFile', $kf, '-BaselineFile', $mf)
    $o = & powershell @a; $c0 = $LASTEXITCODE
    Check 'MUST FIRE  no committed mark is COULD NOT EVALUATE (exit 3), never a pass' ($c0 -eq 3) ("exit $c0")
    $o = & powershell @($a + '-Tighten'); $c1 = $LASTEXITCODE; $o1 = ($o | Select-Object -Last 2) -join ' | '
    Check 'CLEAN TWIN  -Tighten records the day-one mark (2 keys)' (($c1 -eq 0) -and (Test-Path $mf) -and ([int](Read-JsonFile $mf).count -eq 2)) ("exit $c1 " + $o1)
    [IO.File]::WriteAllText($rf, (ConvertTo-Json -InputObject @((Rw 'Shallots' 'shallots'), (Rw 'Pork Chorizo' 'ground-pork')) -Depth 4), $enc)
    $h0 = (Get-FileHash -LiteralPath $mf).Hash
    $o = & powershell @a; $c2 = $LASTEXITCODE
    Check 'MUST NOT FIRE  a FALL exits 0, says it can tighten, and leaves the mark byte-identical' (($c2 -eq 0) -and ((Get-FileHash -LiteralPath $mf).Hash -eq $h0) -and (($o -join ' ') -match 'CAN tighten')) ("exit $c2")
    [IO.File]::WriteAllText($rf, (ConvertTo-Json -InputObject @((Rw 'Shallots' 'onions'), (Rw 'Pork Chorizo' 'ground-pork'), (Rw 'Shallot Rings' 'onions')) -Depth 4), $enc)
    $o = & powershell @a; $c3 = $LASTEXITCODE
    Check 'MUST FIRE  a NEW finding key is a RISE (exit 2) and names it' (($c3 -eq 2) -and (($o -join ' ') -match 'Shallot Rings')) ("exit $c3")
  } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

  if ($ran -ne 21) { Write-Output ('audit-ingredient-identity SELF-TEST FAIL - ran ' + $ran + ' of 21 cases'); Exit-Guard -Name 'INGREDIENT-IDENTITY' -Code 1 -Summary ('selftest ran=' + $ran) }
  if ($bad -gt 0) { Write-Output ('audit-ingredient-identity SELF-TEST FAIL (' + $bad + ' of ' + $ran + ')'); Exit-Guard -Name 'INGREDIENT-IDENTITY' -Code 1 -Summary ('selftest fail=' + $bad) }
  Write-Output ('audit-ingredient-identity SELF-TEST PASS (' + $ran + ' cases)')
  Exit-Guard -Name 'INGREDIENT-IDENTITY' -Code 0 -Summary ('selftest pass cases=' + $ran)
}

$res = Invoke-IdentityRun
foreach ($l in $res.Lines) { Write-Output $l }
Exit-Guard -Name 'INGREDIENT-IDENTITY' -Code $res.Code -Summary ('exit=' + $res.Code)
