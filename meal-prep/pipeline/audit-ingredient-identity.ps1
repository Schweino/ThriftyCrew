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
  (c) RETIRED 2026-09-26. It asked about ONE store per costed line, on one pricing surface: it skipped 946 of 7,616
      board-basis lines (board:<id>:recipeboard-* and board:<id>:nomem:*), never read the 234 feed:<id> lines that
      price through grocery/recipe-floor-id-map.json, and keyed without the product (queue 2026-09-22-5a9676).
  (d) EVERY STORE CELL a costed line can be priced from (the card and compute-v2 take the cheapest across all of
      them): each distinct (item, priced id), the id read off board:<id>:* or feed:<id> through the alias map, the
      cell the comparison row or else the recipe-board row, and every product in it must name the ingredient's
      head word unless a reviewed identity_same_as spelling or identity_reviewed says it is the same food. The key
      carries the store and the product, so a standing key never hides the next wrong product in the same cell.
  `substitute` is a finding by name: Brad ruled no substitute of any kind on 2026-09-22.

  INPUTS ARE PASSED, NEVER DISCOVERED (ops/audit-cross-module-reach.ps1: meal-prep may not go looking in grocery's
  outputs). check-ad-cycles' fan-out passes -BoardFile (newest comparison), -RecipeBoardFile (out/recipe-board.json)
  and -AliasMapFile (recipe-floor-id-map.json). Without -BoardFile nothing runs (exit 3). Without either of the
  other two, the pairs that need it are counted BLIND and printed, the run exits 3 unless something ROSE, and the
  cell mark is never written from that partial view. A pair whose id is on neither board is BLIND too: printed and
  counted, never ok, and it does not fail the run (its line prices from no board this check can read).

  RATCHET, TWO MARKS. Findings are KEYED. Checks (a)+(b) ratchet in ops/out/ingredient-identity-baseline.json,
  check (d) in ops/out/ingredient-identity-cell-baseline.json. A key not in its mark is a RISE and exits 2, whatever
  the count does. A fall is spoken and the mark KEPT; -Tighten records it, and records a day-one mark when absent.
  A plain run never writes a mark. The main mark's fall of 2026-09-26 is the union| family moving to the cell mark,
  not findings fixed.

  SCOPE OF A CLEAN REPORT: unsound. A pricing row that names the head word can still be the wrong member of a
  union (Cherry Tomatoes priced by Grape Tomato shares `tomato`), and a qualifier inside one class (pork vs beef
  chorizo) is invisible to a word test. A finding is a candidate to read, not a verdict: the head-word test is
  incomplete where a store's name omits the class word (garbanzo for chickpeas), which is what identity_same_as is for.

  Exit: 0 no rise (fall spoken), 2 a new finding key (a rise), 3 could not evaluate. Last line:
  INGREDIENT-IDENTITY-COMPLETE.

  -RoutesOnly (2026-09-26, queue 2026-09-26-177835, plan-2026-09-26-2): the PUSH-TIME half, run by run-gates through
  meal-prep/pipeline/audit-ingredient-routes.ps1. Check (a) only - rows, commodities, Get-TcGlobalExclude; no board,
  no costed.json, so it is hermetic on a bare checkout - compared per (item, bid) PAIR with the mark's proxy| and
  unrouted| keys (Get-IdentityRouteChanges in the lib). A push whose commodities.json, ingredients.json or matcher
  change moves a row newly off its bid exits 2 naming the row, its new route and the rebid that repairs it; a
  proxy -> unrouted move is spoken, never refused. Exit 3 when a file cannot be read or there is no mark. It never
  writes the mark and ignores -Tighten: the daily data pass above keeps its RISE semantics unchanged.
  SCOPE OF A CLEAN -RoutesOnly REPORT: unsound. It sees a row whose OWN NAME moves; it cannot see a union cell that
  admits another member while the row's name still routes to its bid (Zucchini / Yellow Squash was exactly that).
  A refusal is complete: the row's own name routed differently from its mark, which is the defect.

  REVIEWED KEYS (2026-10-01, queue 2026-09-30-d694ee, plan-2026-10-01-2). The cell mark may carry
  reviewed: [{key, owner, until, why}], a finding triage decided to KEEP while a named queue item owns the question.
  A RISE key that is reviewed and unexpired (until >= today, local date) prints KNOWN <owner> and does not exit 2;
  a key past its until, or with an until that does not parse, is a RISE again. Only
  -Review <key> -Owner <queue id> -Until <yyyy-MM-dd> [-ReviewWhy <text>] writes the list (never a plain run, og-11),
  and it refuses an until in the past or more than $script:MaxReviewDays days ahead, so a review cannot become
  permanent silence. The key carries store AND product, so a different product in a reviewed cell is still a RISE.
  The mark's count and keys are untouched by a review; -Tighten carries the list.
#>
# Declared inputs of its -SelfTest (round 5, design\PLAN-push-gate-diet-2026-09-27.md): the self-test works in a temp sandbox, and what it loads joins the key through the walk. Verified in a sandbox holding only the keyed files: both arms agree.
# gate-inputs: meal-prep\pipeline\audit-ingredient-identity.ps1
[CmdletBinding()]
param(
  [switch]$SelfTest,
  [switch]$Tighten,
  [string]$RowsFile = '',
  [string]$CommoditiesFile = '',
  [string]$BoardFile = '',
  [string]$RecipeBoardFile = '',
  [string]$AliasMapFile = '',
  [string]$CostedFile = '',
  [string]$BaselineFile = '',
  [string]$CellBaselineFile = '',
  [switch]$RoutesOnly,
  [string]$Review = '',
  [string]$Owner = '',
  [string]$Until = '',
  [string]$ReviewWhy = ''
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
if (-not $RowsFile)         { $RowsFile = Join-Path $mp 'db\ingredients.json' }
if (-not $CommoditiesFile)  { $CommoditiesFile = Join-Path $repo 'grocery\commodities.json' }
if (-not $CostedFile)       { $CostedFile = Join-Path $mp 'db\costed.json' }
if (-not $BaselineFile)     { $BaselineFile = Join-Path $repo 'ops\out\ingredient-identity-baseline.json' }
if (-not $CellBaselineFile) { $CellBaselineFile = Join-Path $repo 'ops\out\ingredient-identity-cell-baseline.json' }

function New-IdentityResolver {
  <# name -> commodity id or $null, over a commodity list, through the SAME matcher the board uses. #>
  param($Commodities, [string[]]$GlobalExclude)
  $m = New-CommodityMatcher -Commodities $Commodities -GlobalExclude $GlobalExclude
  return { param($n) $c = Resolve-Commodity -Matcher $m -Name ([string]$n); if ($c) { [string]$c.id } else { $null } }.GetNewClosure()
}

function Invoke-KeyRatchet {
  <# One keyed mark. Returns { Code; Lines }: 0 no rise, 2 a rise, 3 no mark to compare with. $MayWrite is $false
     when the findings came from a partial view, so -Tighten can neither record nor lower that mark from it. #>
  param($Findings, [string]$File, [string]$Label, [string]$Why, [bool]$MayWrite, [string]$ReadFrom)
  $lines = New-Object System.Collections.ArrayList
  $keys = @($Findings | ForEach-Object { [string]$_.key } | Sort-Object -Unique)
  $base = $null
  if (Test-Path $File) { $base = Read-JsonFile $File }
  if ($null -eq $base) {
    if ($Tighten -and $MayWrite) {
      $doc = [ordered]@{ recorded = (Get-Date -Format 'yyyy-MM-dd'); why = $Why; read_from = $ReadFrom; count = $keys.Count; keys = @($keys) }
      [void](Write-TcLfFile -Path $File -Text (([pscustomobject]$doc) | ConvertTo-Json -Depth 4) -NoBom)
      [void]$lines.Add('  ' + $Label + ' mark RECORDED at ' + $keys.Count + ' finding key(s): ' + $File)
      return [pscustomobject]@{ Code = 0; Lines = $lines }
    }
    $how = if ($MayWrite) { '(record one with -Tighten)' } else { '(and none is recorded from a partial view: pass every input)' }
    [void]$lines.Add('audit-ingredient-identity: COULD NOT EVALUATE - no committed ' + $Label + ' mark at ' + $File + ' ' + $how)
    return [pscustomobject]@{ Code = 3; Lines = $lines }
  }
  $known = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($k in @($base.keys)) { [void]$known.Add([string]$k) }
  $rv = Get-ReviewedState $base
  $unmarked = @($Findings | Where-Object { -not $known.Contains([string]$_.key) })
  $kept = @($unmarked | Where-Object { $rv.Live.ContainsKey([string]$_.key) })
  $new = @($unmarked | Where-Object { -not $rv.Live.ContainsKey([string]$_.key) })
  if ($rv.All.Count -gt 0) { [void]$lines.Add(('  {0} reviewed: {1} key(s) unexpired, {2} expired, {3} of them found this run' -f $Label, $rv.Live.Count, ($rv.All.Count - $rv.Live.Count), $kept.Count)) }
  foreach ($x in $kept) { $e = $rv.Live[[string]$x.key]; [void]$lines.Add('  KNOWN ' + [string]$e.owner + ' until ' + [string]$e.until + '  ' + $x.kind + '  ' + $x.detail) }
  if ($new.Count -gt 0) {
    [void]$lines.Add(('  RISE: {0} {1} finding(s) not in the mark of {2} (mark {3}):' -f $new.Count, $Label, [string]$base.recorded, [int]$base.count))
    foreach ($x in $new) {
      $ex = ''; if ($rv.Expired.ContainsKey([string]$x.key)) { $ee = $rv.Expired[[string]$x.key]; $ex = '  (review by ' + [string]$ee.owner + ' EXPIRED, until ' + [string]$ee.until + ')' }
      [void]$lines.Add('  NEW  ' + $x.kind + '  ' + $x.detail + $ex + '  key=' + [string]$x.key)
    }
    return [pscustomobject]@{ Code = 2; Lines = $lines }
  }
  if ($keys.Count -lt [int]$base.count) {
    if ($Tighten -and $MayWrite) {
      $doc = [ordered]@{ recorded = (Get-Date -Format 'yyyy-MM-dd'); why = [string]$base.why; read_from = $ReadFrom; count = $keys.Count; keys = @($keys) }
      if ($rv.All.Count -gt 0) { $doc['reviewed'] = @($rv.All) }
      [void](Write-TcLfFile -Path $File -Text (([pscustomobject]$doc) | ConvertTo-Json -Depth 4) -NoBom)
      [void]$lines.Add(('  {0} mark TIGHTENED {1} -> {2}' -f $Label, [int]$base.count, $keys.Count))
    } elseif ($Tighten) {
      [void]$lines.Add(('  {0} mark KEPT at {1}: a partial view ({2}) cannot tighten it' -f $Label, [int]$base.count, $keys.Count))
    } else {
      [void]$lines.Add(('  {0} ratchet CAN tighten: {1} -> {2} (mark kept; -Tighten records it)' -f $Label, [int]$base.count, $keys.Count))
    }
  }
  return [pscustomobject]@{ Code = 0; Lines = $lines }
}

# A review is a ruling with an end date: the cap is the plausibility bar on a list that silences a page (og-19).
# 30 = about two weekly triage cycles past the 14-day seed; first plausible value, no sweep.
$script:MaxReviewDays = 30

function Get-ReviewedState {
  <# The mark's reviewed list, split by the local date: Live (until >= today) and Expired (past, or an until that does
     not parse, which fails closed). Keyed ORDINALLY: a bare @{} would let a key differing only in case hide. #>
  param($Base)
  $today = (Get-Date).Date
  $all = New-Object System.Collections.ArrayList
  $live = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
  $exp = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
  $p = $Base.PSObject.Properties['reviewed']
  if ($p -and $null -ne $p.Value) {
    foreach ($e in @($p.Value)) {
      if ($null -eq $e) { continue }
      $k = [string]$e.key
      if (-not $k) { continue }
      $row = [pscustomobject][ordered]@{ key = $k; owner = [string]$e.owner; until = [string]$e.until; why = [string]$e.why }
      [void]$all.Add($row)
      $d = [datetime]::MinValue
      $parsed = [datetime]::TryParseExact([string]$e.until, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)
      if ($parsed -and $d.Date -ge $today) { $live[$k] = $row } else { $exp[$k] = $row }
    }
  }
  return [pscustomobject]@{ All = $all.ToArray(); Live = $live; Expired = $exp }
}

function Invoke-ReviewWrite {
  <# -Review <key> -Owner <queue id> -Until <yyyy-MM-dd>: the ONLY writer of the cell mark's reviewed list. Count and
     keys are carried byte-for-byte in meaning; an entry for the same key is replaced. Exit 0 written, 1 refused. #>
  $lines = New-Object System.Collections.ArrayList
  $why = ''
  $d = [datetime]::MinValue
  $today = (Get-Date).Date
  if (-not $Review.StartsWith('cell|', [StringComparison]::Ordinal)) { $why = 'the key must be a cell mark key (cell|item|id|store|product): ' + $Review }
  elseif ($Owner -notmatch '^\d{4}-\d{2}-\d{2}-[0-9a-f]{6}$') { $why = '-Owner must be the queue id that owns the question (yyyy-mm-dd-xxxxxx), got "' + $Owner + '"' }
  elseif (-not [datetime]::TryParseExact($Until, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { $why = '-Until must be yyyy-MM-dd, got "' + $Until + '"' }
  elseif ($d.Date -lt $today) { $why = '-Until ' + $Until + ' is already past' }
  elseif ($d.Date -gt $today.AddDays($script:MaxReviewDays)) { $why = '-Until ' + $Until + ' is more than ' + $script:MaxReviewDays + ' days ahead: a review must expire' }
  elseif (-not (Test-Path $CellBaselineFile)) { $why = 'no cell mark at ' + $CellBaselineFile }
  if ($why) {
    [void]$lines.Add('audit-ingredient-identity -Review: REFUSED - ' + $why + ' (mark not written)')
    return [pscustomobject]@{ Code = 1; Lines = $lines }
  }
  $base = Read-JsonFile $CellBaselineFile
  $rv = Get-ReviewedState $base
  $list = New-Object System.Collections.ArrayList
  foreach ($e in @($rv.All)) { if (-not [string]::Equals([string]$e.key, $Review, [StringComparison]::Ordinal)) { [void]$list.Add($e) } }
  [void]$list.Add([pscustomobject][ordered]@{ key = $Review; owner = $Owner; until = $d.ToString('yyyy-MM-dd'); why = $ReviewWhy })
  $doc = [ordered]@{}
  foreach ($pp in $base.PSObject.Properties) { if ($pp.Name -ne 'reviewed') { $doc[$pp.Name] = $pp.Value } }
  $doc['reviewed'] = $list.ToArray()
  [void](Write-TcLfFile -Path $CellBaselineFile -Text (([pscustomobject]$doc) | ConvertTo-Json -Depth 4) -NoBom)
  [void]$lines.Add(('audit-ingredient-identity -Review: REVIEWED {0} owner {1} until {2}; cell mark count {3} and keys unchanged, {4} reviewed entr(ies)' -f $Review, $Owner, $d.ToString('yyyy-MM-dd'), [int]$base.count, $list.Count))
  return [pscustomobject]@{ Code = 0; Lines = $lines }
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
    if (-not $bf -or -not (Test-Path $bf)) { [void]$lines.Add('audit-ingredient-identity: COULD NOT EVALUATE - check (d) needs -BoardFile <comparison-YYYY-MM-DD.json>; check-ad-cycles passes the newest one'); return [pscustomobject]@{ Code = 3; Lines = $lines } }
    if (-not (Test-Path $CostedFile)) { [void]$lines.Add('audit-ingredient-identity: COULD NOT EVALUATE - no costed.json at ' + $CostedFile); return [pscustomobject]@{ Code = 3; Lines = $lines } }
    $bix = Get-IdentityBoardIndex (Read-JsonFile $bf)
    $rbix = $null
    if ($RecipeBoardFile -and (Test-Path $RecipeBoardFile)) { $rbix = Get-IdentityBoardIndex (Read-JsonFile $RecipeBoardFile) }
    $alias = $null
    if ($AliasMapFile -and (Test-Path $AliasMapFile)) {
      $alias = @{}
      $am = Read-JsonFile $AliasMapFile
      foreach ($pp in $am.map.PSObject.Properties) { $alias[[string]$pp.Name] = [string]$pp.Value }
    }
    $costed = Read-JsonFile $CostedFile
    $f = @(Get-IngredientIdentityFindings -Rows $rows -Resolve $resolve -WeeklyIds $weekly)
    $d = Get-IngredientCellFindings -Rows $rows -Costed $costed -BoardIndex $bix -RecipeBoardIndex $rbix -AliasMap $alias
  } catch {
    [void]$lines.Add('audit-ingredient-identity: COULD NOT EVALUATE - ' + $_.Exception.Message); return [pscustomobject]@{ Code = 3; Lines = $lines }
  }
  $cf = @($d.findings)
  $blind = @($d.blind)
  $partial = ($null -eq $rbix -or $null -eq $alias)
  $inputBlind = @($blind | Where-Object { $_.why -ne 'on neither board' })
  $keys = @($f | ForEach-Object { [string]$_.key } | Sort-Object -Unique)
  $ckeys = @($cf | ForEach-Object { [string]$_.key } | Sort-Object -Unique)
  $kinds = @($f | Group-Object kind | Sort-Object Name | ForEach-Object { $_.Name + '=' + $_.Count }) -join ' '
  $via = @($d.by_via.Keys | Sort-Object | ForEach-Object { $_ + '=' + $d.by_via[$_] }) -join ' '
  $readFrom = (Split-Path $bf -Leaf) + $(if ($rbix) { ' + ' + (Split-Path $RecipeBoardFile -Leaf) } else { '' }) + $(if ($null -ne $alias) { ' + ' + (Split-Path $AliasMapFile -Leaf) } else { '' })
  [void]$lines.Add(('audit-ingredient-identity: {0} vocabulary row(s), {1} costed recipe(s), read {2}: checks (a)+(b) {3} finding(s) [{4}]; check (d) {5} finding key(s) over {6} store cell(s) of {7} (item, priced id) pair(s) from {8} costed line(s) [{9}], {10} reviewed, {11} BLIND' -f @($rows).Count, @($costed).Count, $readFrom, $keys.Count, $kinds, $ckeys.Count, $d.cells, $d.pairs, $d.lines, $via, $d.reviewed, $blind.Count))
  foreach ($b in $blind) { [void]$lines.Add('  BLIND  "' + $b.item + '" -> ' + $b.id + ': ' + $b.why) }
  $r1 = Invoke-KeyRatchet -Findings $f -File $BaselineFile -Label 'main' -Why 'day-one mark of the ingredient identity check (plan-2026-09-22-9); may only fall' -MayWrite $true -ReadFrom $readFrom
  $r2 = Invoke-KeyRatchet -Findings $cf -File $CellBaselineFile -Label 'cell' -Why 'day-one mark of check (d), every store cell a costed line can be priced from (plan-2026-09-26-2, queue 2026-09-22-5a9676); may only fall' -MayWrite (-not $partial) -ReadFrom $readFrom
  foreach ($l in $r1.Lines) { [void]$lines.Add($l) }
  foreach ($l in $r2.Lines) { [void]$lines.Add($l) }
  $code = 0
  if ($r1.Code -eq 2 -or $r2.Code -eq 2) { $code = 2 }
  elseif ($r1.Code -eq 3 -or $r2.Code -eq 3) { $code = 3 }
  elseif ($inputBlind.Count -gt 0) {
    [void]$lines.Add('audit-ingredient-identity: COULD NOT EVALUATE - check (d) could not read ' + $inputBlind.Count + ' of ' + $d.pairs + ' pair(s): pass -RecipeBoardFile and -AliasMapFile (check-ad-cycles passes both)')
    $code = 3
  }
  foreach ($x in $f) { [void]$lines.Add('  ' + $x.kind + '  ' + $x.detail) }
  foreach ($x in $cf) { [void]$lines.Add('  ' + $x.kind + '  ' + $x.detail) }
  return [pscustomobject]@{ Code = $code; Lines = $lines }
}

function Invoke-RoutesOnlyRun {
  <# The push-time pass (-RoutesOnly). Returns [pscustomobject]@{ Code; Lines }: 0 nothing refused (speaks kept),
     2 a pair moved off its bid, 3 could not evaluate. Never reads a board or costed.json, never writes the mark. #>
  $lines = New-Object System.Collections.ArrayList
  try {
    $rows = Read-JsonFile $RowsFile
    $coms = Read-JsonFile $CommoditiesFile
    if (-not (Test-Path $BaselineFile)) { [void]$lines.Add('audit-ingredient-identity -RoutesOnly: COULD NOT EVALUATE - no committed mark at ' + $BaselineFile); return [pscustomobject]@{ Code = 3; Lines = $lines } }
    $base = Read-JsonFile $BaselineFile
    $gex = @(Get-TcGlobalExclude)
    $resolve = New-IdentityResolver -Commodities $coms -GlobalExclude $gex
    $weekly = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($c in @($coms)) { [void]$weekly.Add([string]$c.id) }
    $markKeys = [string[]]@(@($base.keys) | ForEach-Object { [string]$_ })
    $got = Get-IdentityRouteChanges -Rows $rows -Resolve $resolve -WeeklyIds $weekly -MarkKeys $markKeys
    $moves = @($got | Where-Object { $null -ne $_ })
  } catch {
    [void]$lines.Add('audit-ingredient-identity -RoutesOnly: COULD NOT EVALUATE - ' + $_.Exception.Message); return [pscustomobject]@{ Code = 3; Lines = $lines }
  }
  $ref = @($moves | Where-Object { $_.verdict -eq 'REFUSE' })
  $spk = @($moves | Where-Object { $_.verdict -eq 'SPEAK' })
  [void]$lines.Add(('audit-ingredient-identity -RoutesOnly: {0} vocabulary row(s) routed under {1} commodities against the mark of {2}: {3} refused, {4} spoken' -f @($rows).Count, @($coms).Count, [string]$base.recorded, $ref.Count, $spk.Count))
  foreach ($x in $ref) { [void]$lines.Add('  REFUSE  ' + $x.detail) }
  foreach ($x in $spk) { [void]$lines.Add('  SPEAK   ' + $x.detail) }
  if ($ref.Count -gt 0) { return [pscustomobject]@{ Code = 2; Lines = $lines } }
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
  function KindsOf($rows) { $x = @(Get-IngredientIdentityFindings -Rows $rows -Resolve $resolve -WeeklyIds $weekly); return ,@($x | ForEach-Object { [string]$_.kind }) }
  function Bd([string]$id, [object[]]$pairs) { $st = @(); for ($i = 0; $i -lt $pairs.Count; $i += 2) { $st += [pscustomobject]@{ store = [string]$pairs[$i]; item = [string]$pairs[$i + 1] } }; return [pscustomobject]@{ id = $id; cheapest_store = [string]$pairs[0]; stores = $st } }
  function Ix([object[]]$boardRows) { return (Get-IdentityBoardIndex ([pscustomobject]@{ comparison = @($boardRows) })) }
  function Ln([string]$item, [string]$basis, [string]$slug = 'fixture') { return [pscustomobject]@{ slug = $slug; lines = @([pscustomobject]@{ item = $item; basis = $basis }) } }
  function CellRun($rows, $cost, $bix, $rbix = $null, $alias = $null) { return (Get-IngredientCellFindings -Rows $rows -Costed $cost -BoardIndex $bix -RecipeBoardIndex $rbix -AliasMap $alias) }
  function KeysOf($res) { return ,@(@($res.findings) | ForEach-Object { [string]$_.key }) }
  $emptyIx = @{}

  # ACCENTED NAMES NAME THE FOOD (2026-09-27-8161ce). Built from [char] codes: a BOM-less .ps1 reads as ANSI under PS 5.1.
  $emmi = 'Emmi Le Gruy' + [char]0x00E8 + 're cheese, 6 oz., $9.99'
  $gouda = 'Smoked Gouda Cr' + [char]0x00E8 + 'me Cheese'
  Check 'MUST FIRE  "Emmi Le Gruyere" spelled with an e-grave names Gruyere Cheese (the 2026-09-28 Hy-Vee RISE)' (Test-PricingRowNamesIngredient -Ingredient 'Gruyere Cheese' -ProductName $emmi) 'false'
  Check 'MUST NOT FIRE  an accented wrong product ("Smoked Gouda Creme" with an e-grave) still does not name Gruyere Cheese' (-not (Test-PricingRowNamesIngredient -Ingredient 'Gruyere Cheese' -ProductName $gouda)) 'true'
  Check 'CLEAN TWIN  the product KEY of the accented Emmi name is unfolded and unchanged (emmilegruyrecheese6oz999), so no mark key moves' ((ConvertTo-IdentityProductKey $emmi) -eq 'emmilegruyrecheese6oz999') (ConvertTo-IdentityProductKey $emmi)
  Check 'CLEAN TWIN  the ASCII name "Happy Farms ... Swiss Gruyere Cheese 8 OZ" still names Gruyere Cheese' (Test-PricingRowNamesIngredient -Ingredient 'Gruyere Cheese' -ProductName 'Happy Farms Preferred Specialty Shredded Swiss Gruyere Cheese 8 OZ') 'false'

  $k = KindsOf @(Rw 'Shallots' 'onions')
  Check 'MUST FIRE  Shallots bid onions (relation same) is a PROXY: its own name routes to shallots' ($k -contains 'PROXY') ($k -join ',')
  $k = KindsOf @(Rw 'Pork Chorizo' 'ground-pork')
  Check 'MUST FIRE  Pork Chorizo bid ground-pork is a PROXY: its own name routes to mexican-chorizo-fresh' ($k -contains 'PROXY') ($k -join ',')
  $k = KindsOf @(Rw 'Yellow Onion' 'onions')
  Check 'MUST NOT FIRE  Yellow Onion bid onions is the same food' ($k.Count -eq 0) ($k -join ',')
  $k = KindsOf @(Rw 'Shallots' 'shallots')
  Check 'MUST NOT FIRE  the repaired Shallots bid shallots routes to its own bid and reads clean' ($k.Count -eq 0) ($k -join ',')
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
  Check 'MUST NOT FIRE  Fresh Lemon Juice declared derived from lemons (47 g a lemon) stays clean, though its name would route elsewhere' ($k.Count -eq 0) ($k -join ',')
  $k = KindsOf @(Rw 'Lemon Zest' 'lemons' @{ relation = 'derived'; parent_units_per_purchase = 1; yield_g_per_parent_unit = 6; buy_pkg_g = 6 })
  Check 'MUST NOT FIRE  Lemon Zest (buy_pkg_g 6 == 6 x 1 on an each fruit) stays clean' ($k.Count -eq 0) ($k -join ',')

  # (d) FOUNDING CASES, frozen from plan-2026-09-26-2 (queue 2026-09-22-5a9676). Never regenerated.
  # 1. Zucchini costed at board:zucchini:nomem:Aldi, a store key check (c) never matched; Walmart's cell was yellow squash.
  $zix = Ix @(Bd 'zucchini' @('Aldi', 'Zucchini Squash 1 LB', 'Walmart', 'Fresh Yellow Squash, Each'))
  $zres = CellRun @(Rw 'Zucchini' 'zucchini') @(Ln 'Zucchini' 'board:zucchini:nomem:Aldi') $zix
  $zk = KeysOf $zres
  Check 'MUST FIRE  a nomem:Aldi zucchini line names the Walmart yellow squash cell: cell|Zucchini|zucchini|walmart|freshyellowsquasheach' (($zk.Count -eq 1) -and ($zk -contains 'cell|Zucchini|zucchini|walmart|freshyellowsquasheach')) ($zk -join ',')
  $zres = CellRun @(Rw 'Zucchini' 'zucchini') @(Ln 'Zucchini' 'board:zucchini:nomem:Aldi') (Ix @(Bd 'zucchini' @('Aldi', 'Zucchini Squash 1 LB', 'Walmart', 'Fresh Zucchini, Each')))
  Check 'MUST NOT FIRE  the same zucchini cell with Walmart "Fresh Zucchini, Each" has no finding and reads 2 cells' ((@($zres.findings).Count -eq 0) -and ($zres.cells -eq 2)) ((KeysOf $zres) -join ',')
  # 2. Rotini Pasta priced feed:rotini-pasta through the alias map to pasta, whose Aldi cell is spaghetti.
  $pix = Ix @(Bd 'pasta' @('Aldi', 'Reggano Spaghetti'))
  $rres = CellRun @(Rw 'Rotini Pasta' 'rotini-pasta') @(Ln 'Rotini Pasta' 'feed:rotini-pasta') $pix $emptyIx @{ 'rotini-pasta' = 'pasta' }
  $rk = KeysOf $rres
  Check 'MUST FIRE  a feed:rotini-pasta line resolved through the alias map fires on the pasta cell: cell|Rotini Pasta|pasta|aldi|regganospaghetti' ($rk -contains 'cell|Rotini Pasta|pasta|aldi|regganospaghetti') ($rk -join ',')
  $rres = CellRun @(Rw 'Rotini Pasta' 'rotini-pasta') @(Ln 'Rotini Pasta' 'feed:rotini-pasta') $pix $emptyIx $null
  Check 'MUST FIRE  with no alias map the feed: pair is BLIND (counted, never ok) and yields no finding' ((@($rres.blind).Count -eq 1) -and (@($rres.findings).Count -eq 0) -and ([string]$rres.blind[0].why -match 'AliasMapFile')) ('blind=' + @($rres.blind).Count)
  $pp = Resolve-IdentityPricedId -Basis 'feed:cannellini-beans+drained' -AliasMap @{ 'cannellini-beans' = 'canned-white-beans' }
  Check 'CLEAN TWIN  a pack-form suffix is not part of the id: feed:cannellini-beans+drained resolves to canned-white-beans (was BLIND on 2026-09-26)' (($pp.id -eq 'canned-white-beans') -and ($pp.via -eq 'feed-alias')) ([string]$pp.id)
  # 3. A recipe-board-only id: read with the recipe board, BLIND without it.
  $gix = Ix @(Bd '93-7-ground-turkey' @('Walmart', 'Honeysuckle White Ground Chicken, 1 lb'))
  $gres = CellRun @(Rw 'Ground Turkey' '93-7-ground-turkey') @(Ln 'Ground Turkey' 'board:93-7-ground-turkey:recipeboard-walmart') $emptyIx $gix
  Check 'MUST FIRE  a recipeboard-* line is read on the recipe board: a ground chicken cell for Ground Turkey fires' ((KeysOf $gres) -contains 'cell|Ground Turkey|93-7-ground-turkey|walmart|honeysucklewhitegroundchicken1lb') ((KeysOf $gres) -join ',')
  $gres = CellRun @(Rw 'Ground Turkey' '93-7-ground-turkey') @(Ln 'Ground Turkey' 'board:93-7-ground-turkey:recipeboard-walmart') $emptyIx $null
  Check 'MUST FIRE  with no recipe board the same pair is BLIND, never ok' ((@($gres.blind).Count -eq 1) -and (@($gres.findings).Count -eq 0) -and ([string]$gres.blind[0].why -match 'RecipeBoardFile')) ('blind=' + @($gres.blind).Count)
  $nres = CellRun @(Rw 'Ground Turkey' 'ground-turkey') @(Ln 'Ground Turkey' 'board:no-such-id:walmart') $emptyIx $gix
  Check 'MUST FIRE  a pair whose id is on neither board is counted BLIND "on neither board"' ((@($nres.blind).Count -eq 1) -and ([string]$nres.blind[0].why -eq 'on neither board')) ('blind=' + @($nres.blind).Count)
  # 4. Reviewed same-food spellings are scoped to the product: garbanzo is chickpeas, black beans are not.
  $cix = Ix @(Bd 'chickpeas' @('Aldi', 'Aldi Garbanzo Beans 15.5 OZ', "Baker's", 'Kroger Black Beans 15 oz'))
  $cln = @(Ln 'Chickpeas' 'board:chickpeas:aldi')
  $ck = KeysOf (CellRun @(Rw 'Chickpeas' 'chickpeas') $cln $cix)
  Check 'MUST FIRE  with no record, "Aldi Garbanzo Beans 15.5 OZ" in the chickpeas cell is a finding' ($ck -contains 'cell|Chickpeas|chickpeas|aldi|aldigarbanzobeans155oz') ($ck -join ',')
  $gar = @{ identity_same_as = @([pscustomobject]@{ product = '\bgarbanzo\b'; reason = 'garbanzo beans are chickpeas' }) }
  $ck = KeysOf (CellRun @(Rw 'Chickpeas' 'chickpeas' $gar) $cln $cix)
  Check 'MUST NOT FIRE  identity_same_as "\bgarbanzo\b" silences the Aldi garbanzo row' (-not ($ck -contains 'cell|Chickpeas|chickpeas|aldi|aldigarbanzobeans155oz')) ($ck -join ',')
  Check 'CLEAN TWIN  the same record leaves "Kroger Black Beans" in the same cell a finding' (($ck.Count -eq 1) -and ($ck -contains 'cell|Chickpeas|chickpeas|bakers|krogerblackbeans15oz')) ($ck -join ',')
  # 5. A derived row is asked about its PARENT; a reviewed row silences its cells.
  $eres = CellRun @(Rw 'Egg Yolk' 'eggs' @{ relation = 'derived'; parent_units_per_purchase = 12; yield_g_per_parent_unit = 17; buy_pkg_g = 204 }) @(Ln 'Egg Yolk' 'board:eggs:walmart') (Ix @(Bd 'eggs' @('Walmart', 'Great Value Large White Eggs, 60 Count')))
  Check 'MUST NOT FIRE  Egg Yolk declared derived from eggs is silent on "Great Value Large White Eggs, 60 Count"' ((@($eres.findings).Count -eq 0) -and ($eres.cells -eq 1)) ((KeysOf $eres) -join ',')
  $tres = CellRun @(Rw 'High Fiber Tortilla' 'tortillas' @{ identity_reviewed = 'the carb-balance wrap is the high fiber tortilla' }) @(Ln 'High Fiber Tortilla' 'board:tortillas:walmart') (Ix @(Bd 'tortillas' @('Walmart', 'Mission Carb Balance Wraps')))
  Check 'MUST NOT FIRE  an identity_reviewed row silences every cell and is counted reviewed' ((@($tres.findings).Count -eq 0) -and ($tres.reviewed -eq 1)) ((KeysOf $tres) -join ',')
  # 6. Check (c)'s founding union: a thigh line costed at Sam's (which (c) passed) is still reachable by the Walmart drumstick cell.
  $thix = Ix @(Bd 'chicken-thighs' @('Walmart', 'Tyson Fresh Chicken Drumstick, 10 lb Bag', "Sam's Club", "Member's Mark Bone-In Chicken Thighs, priced per pound"))
  $thk = KeysOf (CellRun @(Rw 'Bone-In Skin-On Chicken Thighs' 'chicken-thighs') @(Ln 'Bone-In Skin-On Chicken Thighs' "board:chicken-thighs:sam's club") $thix)
  Check "MUST FIRE  a thigh line costed at Sam's still names the Walmart drumstick cell, and not Sam's own thighs" (($thk.Count -eq 1) -and ($thk[0] -like 'cell|Bone-In Skin-On Chicken Thighs|chicken-thighs|walmart|*')) ($thk -join ',')
  $zsk = KeysOf (CellRun @(Rw 'Orange Zest' 'oranges' ($oz + @{ buy_pkg_g = 6 })) @(Ln 'Orange Zest' 'board:oranges:walmart') (Ix @(Bd 'oranges' @('Walmart', 'Navel Oranges, 8 lb Bag'))))
  Check 'MUST NOT FIRE  a derived zest line is asked about its PARENT and "Navel Oranges" answers' ($zsk.Count -eq 0) ($zsk -join ',')
  # 7. The Red Pepper Flakes record (queue 2026-09-23-9999c0), now over every cell.
  $rpx = Ix @(Bd 'red-pepper-flakes' @('Walmart', 'Great Value Crushed Red Pepper, 12 oz', 'Hy-Vee', 'Hy-Vee Paprika, 2.5 oz'))
  $rpl = @(Ln 'Red Pepper Flakes' 'board:red-pepper-flakes:walmart')
  $same = @{ identity_same_as = @([pscustomobject]@{ product = '\bcrushed\s+red\s+pepper\b'; reason = 'crushed red pepper IS red pepper flakes' }) }
  $k = KeysOf (CellRun @(Rw 'Red Pepper Flakes' 'red-pepper-flakes') $rpl $rpx)
  Check 'MUST FIRE  with no record, "Great Value Crushed Red Pepper" in the red-pepper-flakes cell is a finding' (@($k | Where-Object { $_ -like '*|walmart|*' }).Count -eq 1) ($k -join ',')
  $k = KeysOf (CellRun @(Rw 'Red Pepper Flakes' 'red-pepper-flakes' $same) $rpl $rpx)
  Check 'MUST NOT FIRE  a reviewed identity_same_as naming "crushed red pepper" silences that spelling' (@($k | Where-Object { $_ -like '*|walmart|*' }).Count -eq 0) ($k -join ',')
  Check 'CLEAN TWIN  the same record does NOT silence the Hy-Vee paprika row in the same cell' (@($k | Where-Object { $_ -like '*|hyvee|hyveepaprika25oz' }).Count -eq 1) ($k -join ',')
  $k = KeysOf (CellRun @(Rw 'Red Pepper Flakes' 'red-pepper-flakes' @{ identity_same_as = @([pscustomobject]@{ product = '\bcrushed\s+red\s+pepper\b'; reason = '' }) }) $rpl $rpx)
  Check 'MUST FIRE  a record with no reason silences nothing' (@($k | Where-Object { $_ -like '*|walmart|*' }).Count -eq 1) ($k -join ',')
  # 8. A store listing two products is asked about both (the store -> product map keeps only the last).
  $k = KeysOf (CellRun @(Rw 'Zucchini' 'zucchini') @(Ln 'Zucchini' 'board:zucchini:walmart') (Ix @(Bd 'zucchini' @('Walmart', 'Fresh Yellow Squash, Each', 'Walmart', 'Fresh Zucchini, Each'))))
  Check 'MUST FIRE  a store that lists yellow squash before zucchini still names the squash row' ($k -contains 'cell|Zucchini|zucchini|walmart|freshyellowsquasheach') ($k -join ',')
  # 9. Brad 2026-09-26, Q-2026-09-26-form-style B ("shape same, style own"): the FORM records on db\ingredients.json,
  # frozen here verbatim with the real cell holders from the 2026-09-26 cell mark. A pasta shape is the same food;
  # whole grain is not a shape, so the Baker's whole grain penne stays a finding.
  $pastaSame = @{ identity_same_as = @([pscustomobject]@{ product = '^(?!.*\bwhole[\s-]*(?:grain|wheat)\b).*\b(?:pasta|spaghetti|penne|rigate|rotini|ziti|shells?|fettuccine|orzo|linguine|elbows?|macaroni)\b'; reason = 'a different shape of dry pasta is the same food by weight' }) }
  $psx = Ix @(Bd 'pasta' @('Hy-Vee', 'Hy-Vee Penne Rigate', "Baker's", 'Kroger 100% Whole Grain Penne Rigate', "Sam's Club", 'Barilla Pasta Variety Pack, 1 lb., 6 pk.'))
  $psl = @(Ln 'Pasta Shells' 'board:pasta:hyvee')
  $k = KeysOf (CellRun @(Rw 'Pasta Shells' 'pasta') $psl $psx)
  Check 'MUST FIRE  with no record, "Hy-Vee Penne Rigate" in the pasta cell is a finding for Pasta Shells' ($k -contains 'cell|Pasta Shells|pasta|hyvee|hyveepennerigate') ($k -join ',')
  $k = KeysOf (CellRun @(Rw 'Pasta Shells' 'pasta' $pastaSame) $psl $psx)
  Check 'MUST NOT FIRE  the pasta-shape record silences penne rigate and the variety pack for Pasta Shells' ((-not ($k -contains 'cell|Pasta Shells|pasta|hyvee|hyveepennerigate')) -and (@($k | Where-Object { $_ -like '*|samsclub|*' }).Count -eq 0)) ($k -join ',')
  Check 'CLEAN TWIN  the same record leaves "Kroger 100% Whole Grain Penne Rigate" a finding (whole grain is not a shape)' (($k.Count -eq 1) -and ($k -contains 'cell|Pasta Shells|pasta|bakers|kroger100wholegrainpennerigate')) ($k -join ',')
  $pinSame = @{ identity_same_as = @([pscustomobject]@{ product = '\bcrushed\s+pineapple\b'; reason = 'crushed and chunk are two cuts of the same canned pineapple' }) }
  $pnx = Ix @(Bd 'canned-pineapple' @('Walmart', 'Great Value Canned Crushed Pineapple, 20 oz', 'Aldi', 'Sweet Harvest Pineapple Juice 46 FL OZ'))
  $k = KeysOf (CellRun @(Rw 'Pineapple Chunks' 'canned-pineapple' $pinSame) @(Ln 'Pineapple Chunks' 'board:canned-pineapple:walmart') $pnx)
  Check 'MUST NOT FIRE  the crushed-pineapple record silences the Walmart crushed can for Pineapple Chunks' (@($k | Where-Object { $_ -like '*|walmart|*' }).Count -eq 0) ($k -join ',')
  Check 'CLEAN TWIN  the same record leaves a pineapple JUICE row in the cell a finding' (@($k | Where-Object { $_ -like '*|aldi|*' }).Count -eq 1) ($k -join ',')
  # 10. 2026-09-27-c989c6: the FORM vocabulary drifted from the commodity it describes (angel hair admitted by the pasta
  # include, missing from the shape list) and Mayonnaise lacked its own "mayo" spelling. These cases read the LIVE
  # rows in db\ingredients.json and the LIVE pasta include, so a later edit of either copy goes red here by name.
  function PastaShapeGaps([object[]]$includes, [string]$sameAs) {
    $gaps = New-Object 'System.Collections.Generic.List[string]'
    foreach ($inc in $includes) {
      foreach ($alt in ([string]$inc -split '\|')) {
        $w = (($alt -replace '\\b', '') -replace '\\s[+*]?', ' ').Trim()
        if ($w -match '[\\\[\](){}?*+^$.]') { $gaps.Add('underivable:' + $alt); continue }
        if (-not ('Store Brand ' + $w + ' 16 oz' -match $sameAs)) { $gaps.Add($w) }
      }
    }
    return ,$gaps.ToArray()
  }
  $liveRowsRaw = Read-JsonFile $RowsFile
  $liveRows = @($liveRowsRaw | ForEach-Object { $_ })
  $liveComs = Read-JsonFile $CommoditiesFile
  $liveComArr = @($(if ($liveComs.PSObject.Properties['commodities']) { $liveComs.commodities } else { $liveComs }))
  $livePasta = @($liveComArr | Where-Object { [string]$_.id -eq 'pasta' })
  $pastaForms = @('Fettuccine', 'Orzo Pasta', 'Pasta Shells', 'Rotini Pasta', 'Spaghetti', 'Ziti Pasta')
  function LiveSame([string]$item) { $r = @($liveRows | Where-Object { [string]$_.item -eq $item }); if ($r.Count -ne 1) { return @() }; return @($r[0].identity_same_as) }
  $g = PastaShapeGaps @($livePasta[0].include) ([string]$pastaSame.identity_same_as[0].product)
  Check 'MUST FIRE  the shape check names "angel hair" against the 2026-09-26 pasta FORM record (the include admits it, the shape list did not)' ($g -contains 'angel hair') ($g -join ',')
  $gl = @(); foreach ($f in $pastaForms) { $s = @(LiveSame $f); if ($s.Count -eq 0) { $gl += ($f + ':no-record'); continue }; foreach ($x in (PastaShapeGaps @($livePasta[0].include) ([string]$s[0].product))) { $gl += ($f + ':' + $x) } }
  Check 'MUST NOT FIRE  LIVE: every shape word the live pasta include admits is admitted by all 6 live pasta FORM records' (($livePasta.Count -eq 1) -and ($gl.Count -eq 0)) ($gl -join ',')
  $ahx = Ix @(Bd 'pasta' @('Family Fare', 'Our Family Angel Hair 16 Oz', 'Walmart', 'Miracle Noodle Angel Hair Konjac Noodles, Naturally Low Carb, Gluten Free, 7 oz'))
  $ahl = @(Ln 'Spaghetti' 'board:pasta:aldi')
  $k = KeysOf (CellRun @(Rw 'Spaghetti' 'pasta' $pastaSame) $ahl $ahx)
  Check 'MUST FIRE  the 2026-09-26 record leaves "Our Family Angel Hair 16 Oz" a finding for Spaghetti (the founding key)' (@($k | Where-Object { $_ -like '*angelhair16oz' }).Count -eq 1) ($k -join ',')
  $k = KeysOf (CellRun @(Rw 'Spaghetti' 'pasta' @{ identity_same_as = @(LiveSame 'Spaghetti') }) $ahl $ahx)
  Check 'MUST NOT FIRE  LIVE: the Spaghetti record silences "Our Family Angel Hair 16 Oz"' (@($k | Where-Object { $_ -like '*angelhair16oz' }).Count -eq 0) ($k -join ',')
  Check 'MUST FIRE  LIVE: a konjac angel hair in the pasta cell still fires on Spaghetti (second defence behind the pasta exclude)' (@($k | Where-Object { $_ -like '*konjac*' }).Count -eq 1) ($k -join ',')
  $myx = Ix @(Bd 'mayonnaise' @('Family Fare', 'Our Family Mayo, Real 30 Fl Oz', "Baker's", 'Kroger Olive Oil Mayo'))
  $k = KeysOf (CellRun @(Rw 'Mayonnaise' 'mayonnaise' @{ identity_same_as = @(LiveSame 'Mayonnaise') }) @(Ln 'Mayonnaise' 'board:mayonnaise:aldi') $myx)
  Check 'MUST NOT FIRE  LIVE: the Mayonnaise record silences "Our Family Mayo, Real 30 Fl Oz"' (@($k | Where-Object { $_ -like '*ourfamilymayo*' }).Count -eq 0) ($k -join ',')
  Check 'MUST FIRE  LIVE: "Kroger Olive Oil Mayo" stays a finding on Mayonnaise (olive oil mayo is unproven)' (@($k | Where-Object { $_ -like '*krogeroliveoilmayo*' }).Count -eq 1) ($k -join ',')
  $sdx = Ix @(Bd 'sun-dried-tomatoes' @("Baker's", 'California Sun Dry Sun-Dried Julienne Cut Tomatoes in Oil with Herbs', 'Family Fare', 'California Sun Dry Sun Dried Tomatoes Julienne Ct'))
  $k = KeysOf (CellRun @(Rw 'Sun-Dried Tomatoes (Oil-Packed)' 'sun-dried-tomatoes' @{ identity_same_as = @(LiveSame 'Sun-Dried Tomatoes (Oil-Packed)') }) @(Ln 'Sun-Dried Tomatoes (Oil-Packed)' 'board:sun-dried-tomatoes:bakers') $sdx)
  Check 'MUST NOT FIRE  LIVE: the oil-packed record silences the Baker''s jar "in Oil with Herbs"' (@($k | Where-Object { $_ -like '*inoilwithherbs*' }).Count -eq 0) ($k -join ',')
  Check 'CLEAN TWIN  LIVE: the Family Fare "Julienne Ct" jar that never says oil stays a finding' (@($k | Where-Object { $_ -like '*juliennect*' }).Count -eq 1) ($k -join ',')
  # 11. 2026-09-29 (queue 2026-09-29-59b8fc, folded into 2026-09-26-177835): the third RISE row of comparison-2026-09-29,
  # frozen verbatim beside its dry-form twin. Neither name says oil, so the live record must not silence the Hy-Vee
  # listing by name alone (its 8.5 oz at $0.8224/oz reads as a jar, but size is not a name word), and the dry halves bag
  # stays a finding too.
  $hvx = Ix @(Bd 'sun-dried-tomatoes' @('Hy-Vee', 'Hy-Vee Sun-Dried Tomatoes Halves', "Baker's", 'California Sun-Dry Sun-Dried Tomatoes Halves'))
  $k = KeysOf (CellRun @(Rw 'Sun-Dried Tomatoes (Oil-Packed)' 'sun-dried-tomatoes' @{ identity_same_as = @(LiveSame 'Sun-Dried Tomatoes (Oil-Packed)') }) @(Ln 'Sun-Dried Tomatoes (Oil-Packed)' 'board:sun-dried-tomatoes:walmart') $hvx)
  Check 'MUST FIRE  LIVE: "Hy-Vee Sun-Dried Tomatoes Halves" (no oil word) stays a finding on the oil-packed row' (@($k | Where-Object { $_ -like '*|hyvee|*' }).Count -eq 1) ($k -join ',')
  Check 'MUST FIRE  LIVE: the dry 3 oz "California Sun-Dry Sun-Dried Tomatoes Halves" bag stays a finding on the oil-packed row' (@($k | Where-Object { $_ -like '*|bakers|*' }).Count -eq 1) ($k -join ',')

  # THE MAPPER'S WRITE: the standing REUSE bone-in skin-on chicken thighs -> chicken-thighs is refused while the
  # cell is won by a drumstick bag, and a term that routes elsewhere is refused outright.
  $why = Test-ReuseIdentity -Term 'bone-in skin-on chicken thighs' -Id 'chicken-thighs' -Resolve $resolve -WeeklyIds $weekly -BoardIndex $thix
  Check 'MUST FIRE  the mapper refuses the chicken-thighs REUSE while its crown is the drumstick bag' ([bool]$why) ([string]$why)
  $why = Test-ReuseIdentity -Term 'pork chorizo' -Id 'ground-pork' -Resolve $resolve -WeeklyIds $weekly -BoardIndex $thix
  Check 'MUST FIRE  the mapper refuses pork chorizo -> ground-pork (the chorizo-as-ground-pork line)' ([bool]$why) ([string]$why)
  $why = Test-ReuseIdentity -Term 'yellow onion' -Id 'onions' -Resolve $resolve -WeeklyIds $weekly -BoardIndex (Ix @(Bd 'onions' @('Walmart', 'Fresh Yellow Onions, 3 lb Bag')))
  Check 'MUST NOT FIRE  the mapper does not refuse yellow onion -> onions' ($null -eq $why) ([string]$why)
  Check 'CLEAN TWIN  Get-TokenStem folds the plural the vocabulary missed: shallots -> shallot, and keeps asparagus' (((Get-TokenStem 'shallots') -eq 'shallot') -and ((Get-TokenStem 'asparagus') -eq 'asparagus')) ((Get-TokenStem 'shallots') + '/' + (Get-TokenStem 'asparagus'))

  # THE TWO RATCHETS, run as a child over temp files: a fall keeps the mark byte-identical, -Tighten writes it, a
  # new key is a RISE (exit 2), a partial view is exit 3 and writes nothing, and a standing cell key does not hide
  # a new product in the same cell.
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('iid-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  try {
    $enc = New-Object System.Text.UTF8Encoding($false)
    $cf = Join-Path $tmp 'c.json'; $rf = Join-Path $tmp 'r.json'; $bfile = Join-Path $tmp 'comparison-2026-09-22.json'; $kf = Join-Path $tmp 'k.json'
    $rbf = Join-Path $tmp 'recipe-board.json'; $af = Join-Path $tmp 'alias.json'; $mf = Join-Path $tmp 'mark.json'; $cmf = Join-Path $tmp 'cellmark.json'
    function WriteBoard([string]$bakersProduct) { [IO.File]::WriteAllText($bfile, ([pscustomobject]@{ comparison = @((Bd 'chickpeas' @('Aldi', 'Aldi Garbanzo Beans 15.5 OZ', "Baker's", $bakersProduct))) } | ConvertTo-Json -Depth 6), $enc) }
    $rowsB = @((Rw 'Shallots' 'onions'), (Rw 'Pork Chorizo' 'ground-pork'), (Rw 'Chickpeas' 'chickpeas'), (Rw 'Ground Turkey' '93-7-ground-turkey'))
    [IO.File]::WriteAllText($cf, (ConvertTo-Json -InputObject @($coms) -Depth 5), $enc)
    WriteBoard 'Kroger Chickpeas 15 oz'
    [IO.File]::WriteAllText($rbf, ([pscustomobject]@{ comparison = @((Bd '93-7-ground-turkey' @('Walmart', 'Honeysuckle White 93% Lean Ground Turkey, 1 lb'))) } | ConvertTo-Json -Depth 6), $enc)
    [IO.File]::WriteAllText($af, '{"map":{}}', $enc)
    [IO.File]::WriteAllText($kf, (ConvertTo-Json -InputObject @([pscustomobject]@{ slug = 'fx'; lines = @([pscustomobject]@{ item = 'Chickpeas'; basis = 'board:chickpeas:aldi' }, [pscustomobject]@{ item = 'Ground Turkey'; basis = 'board:93-7-ground-turkey:recipeboard-walmart' }) }) -Depth 5), $enc)
    [IO.File]::WriteAllText($rf, (ConvertTo-Json -InputObject $rowsB -Depth 4), $enc)
    $base = @('-NoProfile', '-File', $PSCommandPath, '-RowsFile', $rf, '-CommoditiesFile', $cf, '-BoardFile', $bfile, '-CostedFile', $kf, '-BaselineFile', $mf, '-CellBaselineFile', $cmf)
    $a = $base + @('-RecipeBoardFile', $rbf, '-AliasMapFile', $af)
    $o = & powershell @a; $c0 = $LASTEXITCODE
    Check 'MUST FIRE  no committed mark is COULD NOT EVALUATE (exit 3), never a pass' ($c0 -eq 3) ("exit $c0")
    $o = & powershell @($a + '-Tighten'); $c1 = $LASTEXITCODE; $o1 = ($o | Select-Object -Last 2) -join ' | '
    Check 'CLEAN TWIN  -Tighten records both day-one marks (main 2 keys, cell 1 key: the garbanzo row)' (($c1 -eq 0) -and (Test-Path $mf) -and ([int](Read-JsonFile $mf).count -eq 2) -and (Test-Path $cmf) -and ([int](Read-JsonFile $cmf).count -eq 1)) ("exit $c1 " + $o1)
    [IO.File]::WriteAllText($rf, (ConvertTo-Json -InputObject @((Rw 'Shallots' 'shallots'), (Rw 'Pork Chorizo' 'ground-pork'), (Rw 'Chickpeas' 'chickpeas'), (Rw 'Ground Turkey' '93-7-ground-turkey')) -Depth 4), $enc)
    $h0 = (Get-FileHash -LiteralPath $mf).Hash
    $o = & powershell @a; $c2 = $LASTEXITCODE
    Check 'MUST NOT FIRE  a FALL exits 0, says it can tighten, and leaves the mark byte-identical' (($c2 -eq 0) -and ((Get-FileHash -LiteralPath $mf).Hash -eq $h0) -and (($o -join ' ') -match 'CAN tighten')) ("exit $c2")
    [IO.File]::WriteAllText($rf, (ConvertTo-Json -InputObject ($rowsB + @(Rw 'Shallot Rings' 'onions')) -Depth 4), $enc)
    $o = & powershell @a; $c3 = $LASTEXITCODE
    Check 'MUST FIRE  a NEW finding key is a RISE (exit 2) and names it' (($c3 -eq 2) -and (($o -join ' ') -match 'Shallot Rings')) ("exit $c3")
    [IO.File]::WriteAllText($rf, (ConvertTo-Json -InputObject $rowsB -Depth 4), $enc)
    $hc = (Get-FileHash -LiteralPath $cmf).Hash
    $o = & powershell @($base + @('-AliasMapFile', $af, '-Tighten')); $c4 = $LASTEXITCODE
    Check 'MUST FIRE  run without -RecipeBoardFile, the recipe-board pair is BLIND: exit 3, and -Tighten leaves the cell mark byte-identical' (($c4 -eq 3) -and (($o -join ' ') -match 'BLIND  "Ground Turkey"') -and ((Get-FileHash -LiteralPath $cmf).Hash -eq $hc)) ("exit $c4")
    WriteBoard 'Kroger Black Beans 15 oz'
    $o = & powershell @a; $c5 = $LASTEXITCODE
    Check 'MUST FIRE  a standing chickpeas key does not hide a NEW "Kroger Black Beans" product in the same cell: RISE, exit 2' (($c5 -eq 2) -and (($o -join ' ') -match 'NEW  CELL .*Kroger Black Beans')) ("exit $c5")

    # REVIEWED KEYS (queue 2026-09-30-d694ee): the shape of the three kept findings (Family Fare Julienne Ct, Hy-Vee
    # Halves, Kroger Olive Oil Mayo) re-paging daily because a kept key could never enter the mark. The Black Beans key
    # stands in for one of them; its key is derived by the SAME lib the data pass calls, never typed.
    $dd = CellRun $rowsB (Read-JsonFile $kf) (Get-IdentityBoardIndex (Read-JsonFile $bfile)) (Get-IdentityBoardIndex (Read-JsonFile $rbf)) @{}
    $bbKeys = @(@($dd.findings) | Where-Object { [string]$_.detail -match 'Kroger Black Beans' } | ForEach-Object { [string]$_.key })
    $bbKey = if ($bbKeys.Count -eq 1) { $bbKeys[0] } else { 'cell|no-black-beans-key-derived' }
    $own = '2026-09-29-465acc'
    function RvCount($j) { $p = $j.PSObject.Properties['reviewed']; if ($p -and $null -ne $p.Value) { return @($p.Value).Count }; return 0 }
    $day = { param([int]$n) (Get-Date).Date.AddDays($n).ToString('yyyy-MM-dd') }
    $cnt0 = [int](Read-JsonFile $cmf).count
    $o = & powershell @($base + @('-Review', $bbKey, '-Owner', $own, '-Until', (& $day 14), '-ReviewWhy', 'fixture')); $e1 = $LASTEXITCODE
    $m1 = Read-JsonFile $cmf
    Check 'CLEAN TWIN  -Review writes one reviewed entry (owner 2026-09-29-465acc, 14 days) and leaves the mark count and keys unchanged' (($e1 -eq 0) -and ($bbKeys.Count -eq 1) -and ((RvCount $m1) -eq 1) -and ([int]$m1.count -eq $cnt0) -and (@($m1.keys).Count -eq $cnt0)) ("exit $e1 keys=$($bbKeys.Count) " + ($o -join ' | '))
    $hr = (Get-FileHash -LiteralPath $cmf).Hash
    $o = & powershell @a; $e2 = $LASTEXITCODE
    Check 'CLEAN TWIN  the reviewed unexpired key exits 0, prints KNOWN 2026-09-29-465acc, no RISE, and a plain run leaves the mark byte-identical' (($e2 -eq 0) -and (($o -join ' ') -match 'KNOWN 2026-09-29-465acc') -and (($o -join ' ') -notmatch 'RISE') -and ((Get-FileHash -LiteralPath $cmf).Hash -eq $hr)) ("exit $e2 " + ($o -join ' | '))
    [IO.File]::WriteAllText($bfile, ([pscustomobject]@{ comparison = @((Bd 'chickpeas' @('Aldi', 'Aldi Garbanzo Beans 15.5 OZ', "Baker's", 'Kroger Black Beans 15 oz', 'Hy-Vee', 'Hy-Vee Black Beans 15 oz'))) } | ConvertTo-Json -Depth 6), $enc)
    $o = & powershell @a; $e3 = $LASTEXITCODE; $oj = $o -join ' '
    Check 'MUST FIRE  a new unreviewed product in the same commodity (Hy-Vee Black Beans) exits 2 RISE 1 naming only it, while the reviewed key prints KNOWN' (($e3 -eq 2) -and ($oj -match 'RISE: 1 cell') -and (@($o | Where-Object { $_ -match '^\s*NEW  CELL .*Hy-Vee Black Beans' }).Count -eq 1) -and (@($o | Where-Object { $_ -match '^\s*NEW  CELL .*Kroger Black Beans' }).Count -eq 0) -and ($oj -match 'KNOWN 2026-09-29-465acc')) ("exit $e3 " + ($o -join ' | '))
    WriteBoard 'Kroger Black Beans 15 oz'
    function SetUntil([string]$u) { $j = Read-JsonFile $cmf; $j.reviewed[0].until = $u; [IO.File]::WriteAllText($cmf, ($j | ConvertTo-Json -Depth 4), $enc) }
    SetUntil (& $day 0)
    $o = & powershell @a; $e4 = $LASTEXITCODE
    Check 'CLEAN TWIN  a review whose until is TODAY (AT the bar) is still live: exit 0, KNOWN' (($e4 -eq 0) -and (($o -join ' ') -match 'KNOWN 2026-09-29-465acc')) ("exit $e4 " + ($o -join ' | '))
    SetUntil (& $day -1)
    $o = & powershell @a; $e5 = $LASTEXITCODE
    Check 'MUST FIRE  a review whose until was YESTERDAY (one day past the bar) re-raises: exit 2 RISE naming Kroger Black Beans as EXPIRED' (($e5 -eq 2) -and (@($o | Where-Object { $_ -match '^\s*NEW  CELL .*Kroger Black Beans.*EXPIRED' }).Count -eq 1)) ("exit $e5 " + ($o -join ' | '))
    $o = & powershell @($base + @('-Review', $bbKey, '-Owner', $own, '-Until', (& $day 30))); $e6 = $LASTEXITCODE
    $m6 = Read-JsonFile $cmf
    Check 'CLEAN TWIN  -Until 30 days ahead (AT the cap) is written, replacing the key''s old entry (still one entry)' (($e6 -eq 0) -and ((RvCount $m6) -eq 1) -and ([string]$m6.reviewed[0].until -eq (& $day 30))) ("exit $e6 " + ($o -join ' | '))
    $h6 = (Get-FileHash -LiteralPath $cmf).Hash
    $o = & powershell @($base + @('-Review', $bbKey, '-Owner', $own, '-Until', (& $day 31))); $e7 = $LASTEXITCODE
    Check 'MUST FIRE  -Until 31 days ahead (one past the cap) is REFUSED, exit 1, the mark byte-identical: a review must expire' (($e7 -eq 1) -and (($o -join ' ') -match 'REFUSED') -and ((Get-FileHash -LiteralPath $cmf).Hash -eq $h6)) ("exit $e7 " + ($o -join ' | '))
    [IO.File]::WriteAllText($bfile, ([pscustomobject]@{ comparison = @((Bd 'chickpeas' @('Aldi', 'Aldi Chickpeas 15.5 OZ', "Baker's", 'Kroger Chickpeas 15 oz'))) } | ConvertTo-Json -Depth 6), $enc)
    $o = & powershell @($a + '-Tighten'); $e8 = $LASTEXITCODE
    $m8 = Read-JsonFile $cmf
    Check 'MUST NOT FIRE  -Tighten on a cell fall (1 -> 0) finds nothing, exits 0 and carries the reviewed list unchanged' (($e8 -eq 0) -and ([int]$m8.count -eq 0) -and ((RvCount $m8) -eq 1) -and ([string]$m8.reviewed[0].owner -eq $own)) ("exit $e8 " + ($o -join ' | '))
  } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

  # -RoutesOnly, THE PUSH-TIME PAIR CHECK (queue 2026-09-26-177835). FROZEN, never regenerated: lo-mein-noodles' three
  # includes as HEAD held them on 2026-09-26, placed BEFORE egg-noodles, and the founding mark key of 4880ebc98's gap.
  $rLo = @(
    [pscustomobject]@{ id = 'lo-mein-noodles'; include = @('\blo\s*mein\b.{0,20}\bnoodles?\b', '\bnoodles?\b.{0,20}\blo\s*mein\b', '\bchinese\s+lo\s*mein\b'); exclude = @() },
    [pscustomobject]@{ id = 'egg-noodles'; include = @('egg\s+noodles?', 'egg\s+pasta'); exclude = @() })
  $rPep = @(
    [pscustomobject]@{ id = 'pepperoncini'; include = @('pepp?eroncini'); exclude = @() },
    [pscustomobject]@{ id = 'banana-peppers'; include = @('banana\s+pepper'); exclude = @('pepp?eroncini') })
  $rRice = @([pscustomobject]@{ id = 'rice'; include = @('\brice\b'); exclude = @('cooked') })
  $rTor = @(
    [pscustomobject]@{ id = 'tortillas'; include = @('flour\s+tortillas?'); exclude = @() },
    [pscustomobject]@{ id = 'corn-tortillas'; include = @('white\s+corn\s+tortillas?'); exclude = @() })
  function RoutesOf($coms, $rows, [string[]]$mark) {
    $rs = New-IdentityResolver -Commodities $coms -GlobalExclude @('\bzz-fixture-never-matches\b')
    $wk = New-Object 'System.Collections.Generic.HashSet[string]'; foreach ($c in $coms) { [void]$wk.Add([string]$c.id) }
    $g = Get-IdentityRouteChanges -Rows $rows -Resolve $rs -WeeklyIds $wk -MarkKeys $mark
    return ,@($g | Where-Object { $null -ne $_ })
  }
  $x = RoutesOf $rLo @((Rw 'Lo Mein Noodles' 'egg-noodles'), (Rw 'Egg Noodles' 'egg-noodles')) @('unrouted|Lo Mein Noodles|egg-noodles')
  Check 'MUST FIRE  -RoutesOnly: Lo Mein Noodles marked unrouted on egg-noodles now routes to lo-mein-noodles (the 4880ebc98 re-shape) and is REFUSED, naming both' ((@($x | Where-Object { $_.verdict -eq 'REFUSE' -and $_.item -eq 'Lo Mein Noodles' -and $_.route -eq 'lo-mein-noodles' }).Count -eq 1) -and ($x.Count -eq 1)) (($x | ForEach-Object { $_.verdict + ' ' + $_.detail }) -join ' | ')
  $x = RoutesOf $rLo @((Rw 'Lo Mein Noodles' 'lo-mein-noodles'), (Rw 'Egg Noodles' 'egg-noodles')) @()
  $rsLo = New-IdentityResolver -Commodities $rLo -GlobalExclude @('\bzz-fixture-never-matches\b')
  Check 'MUST NOT FIRE  -RoutesOnly: Lo Mein Noodles rebid onto lo-mein-noodles with the mark tightened is silent' ($x.Count -eq 0) (($x | ForEach-Object { $_.detail }) -join ' | ')
  Check 'CLEAN TWIN  Egg Noodles still routes to egg-noodles beside the lo-mein-noodles include (the row sharing the old bid keeps it)' ((& $rsLo 'Egg Noodles') -eq 'egg-noodles') ([string](& $rsLo 'Egg Noodles'))
  $x = RoutesOf $rPep @(Rw 'Pepperoncini' 'banana-peppers') @()
  Check 'MUST FIRE  -RoutesOnly: Pepperoncini bid banana-peppers with no mark key, under the split rules, is REFUSED (on-bid -> off-bid, the shape the split push creates)' ((@($x | Where-Object { $_.verdict -eq 'REFUSE' -and $_.route -eq 'pepperoncini' }).Count -eq 1)) (($x | ForEach-Object { $_.detail }) -join ' | ')
  $x = RoutesOf $rPep @(Rw 'Pepperoncini' 'pepperoncini') @()
  Check 'MUST NOT FIRE  -RoutesOnly: Pepperoncini rebid onto pepperoncini under the split rules is silent' ($x.Count -eq 0) (($x | ForEach-Object { $_.detail }) -join ' | ')
  $x = RoutesOf $rRice @(Rw 'Cooked White Rice' 'rice') @()
  Check 'MUST FIRE  -RoutesOnly: Cooked White Rice bid rice, now routing nowhere with no mark key, is REFUSED (828d5226b)' ((@($x | Where-Object { $_.verdict -eq 'REFUSE' -and $_.route -eq '' }).Count -eq 1)) (($x | ForEach-Object { $_.detail }) -join ' | ')
  $x = RoutesOf $rTor @(Rw 'Corn Tortillas' 'corn-tortillas') @('proxy|Corn Tortillas|corn-tortillas|tortillas')
  Check 'MUST NOT FIRE  -RoutesOnly: a pair marked proxy that now routes nowhere (proxy -> unrouted) SPEAKS and is never refused' (($x.Count -eq 1) -and ($x[0].verdict -eq 'SPEAK')) (($x | ForEach-Object { $_.verdict + ' ' + $_.detail }) -join ' | ')
  $x = RoutesOf $rLo @(Rw 'Lo Mein Noodles' 'egg-noodles') @('proxy|Lo Mein Noodles|egg-noodles|lo-mein-noodles')
  Check 'MUST NOT FIRE  -RoutesOnly: a standing proxy whose mark key is unchanged (the Tandoori Masala shape) is silent' ($x.Count -eq 0) (($x | ForEach-Object { $_.detail }) -join ' | ')
  $x = RoutesOf $rLo @(Rw 'Lo Mein Noodles' 'egg-noodles') @('proxy|Lo Mein Noodles|egg-noodles|ramen')
  Check 'MUST FIRE  -RoutesOnly: a pair marked proxy onto ramen that now routes to lo-mein-noodles (a new commodity took the name) is REFUSED' ((@($x | Where-Object { $_.verdict -eq 'REFUSE' }).Count -eq 1)) (($x | ForEach-Object { $_.detail }) -join ' | ')
  # the same, as a child over temp files: the exit codes run-gates reads through audit-ingredient-routes.ps1
  $tmp2 = Join-Path ([IO.Path]::GetTempPath()) ('iidr-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp2 -ErrorAction Stop | Out-Null
  try {
    $enc = New-Object System.Text.UTF8Encoding($false)
    $cf2 = Join-Path $tmp2 'c.json'; $rf2 = Join-Path $tmp2 'r.json'; $mf2 = Join-Path $tmp2 'mark.json'
    [IO.File]::WriteAllText($cf2, (ConvertTo-Json -InputObject @($rLo) -Depth 5), $enc)
    [IO.File]::WriteAllText($rf2, (ConvertTo-Json -InputObject @((Rw 'Lo Mein Noodles' 'egg-noodles'), (Rw 'Egg Noodles' 'egg-noodles')) -Depth 4), $enc)
    $a2 = @('-NoProfile', '-File', $PSCommandPath, '-RoutesOnly', '-RowsFile', $rf2, '-CommoditiesFile', $cf2, '-BaselineFile', $mf2)
    $o = & powershell @a2; $d0 = $LASTEXITCODE
    Check 'MUST FIRE  -RoutesOnly child with no committed mark is COULD NOT EVALUATE (exit 3), never a pass' (($d0 -eq 3) -and (($o | Select-Object -Last 1) -match 'INGREDIENT-IDENTITY-COMPLETE')) ("exit $d0")
    [IO.File]::WriteAllText($mf2, '{ "recorded": "2026-09-25", "count": 1, "keys": [ "unrouted|Lo Mein Noodles|egg-noodles" ] }', $enc)
    $o = & powershell @a2; $d1 = $LASTEXITCODE
    Check 'MUST FIRE  -RoutesOnly child exits 2 and names Lo Mein Noodles and lo-mein-noodles, with no -BoardFile and no costed.json' (($d1 -eq 2) -and (($o -join ' ') -match 'Lo Mein Noodles') -and (($o -join ' ') -match 'ToBid lo-mein-noodles')) ("exit $d1 " + ($o -join ' | '))
    $h1 = (Get-FileHash -LiteralPath $mf2).Hash
    [IO.File]::WriteAllText($rf2, (ConvertTo-Json -InputObject @((Rw 'Lo Mein Noodles' 'lo-mein-noodles'), (Rw 'Egg Noodles' 'egg-noodles')) -Depth 4), $enc)
    $o = & powershell @($a2 + '-Tighten'); $d2 = $LASTEXITCODE
    Check 'CLEAN TWIN  -RoutesOnly child with the rebid riding the push exits 0 and never writes the mark, even under -Tighten' (($d2 -eq 0) -and ((Get-FileHash -LiteralPath $mf2).Hash -eq $h1)) ("exit $d2")
  } finally { Remove-Item -Recurse -Force $tmp2 -ErrorAction SilentlyContinue }

  if ($ran -ne 80) { Write-Output ('audit-ingredient-identity SELF-TEST FAIL - ran ' + $ran + ' of 80 cases'); Exit-Guard -Name 'INGREDIENT-IDENTITY' -Code 1 -Summary ('selftest ran=' + $ran) }
  if ($bad -gt 0) { Write-Output ('audit-ingredient-identity SELF-TEST FAIL (' + $bad + ' of ' + $ran + ')'); Exit-Guard -Name 'INGREDIENT-IDENTITY' -Code 1 -Summary ('selftest fail=' + $bad) }
  Write-Output ('audit-ingredient-identity SELF-TEST PASS (' + $ran + ' cases)')
  Exit-Guard -Name 'INGREDIENT-IDENTITY' -Code 0 -Summary ('selftest pass cases=' + $ran)
}

$res = if ($Review) { Invoke-ReviewWrite } elseif ($RoutesOnly) { Invoke-RoutesOnlyRun } else { Invoke-IdentityRun }
foreach ($l in $res.Lines) { Write-Output $l }
Exit-Guard -Name 'INGREDIENT-IDENTITY' -Code $res.Code -Summary ('exit=' + $res.Code)
