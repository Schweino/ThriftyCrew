<#
  probe-known-wrong-patterns.ps1 - WHAT WOULD A PATTERN-KEYED known-wrong RULING BLOCK?

  A MEASUREMENT, NOT A GATE. It changes no ruling, no rule and no board. It reads known-wrong.json, the
  gitignored boards and captures, and the review ledgers, and writes one row per ruling per derivation.

  THE QUESTION (Brad, 2026-09-25, ruling Q1-shape-scoped-rulings of grocery\triage-plans\plan-2026-09-20-4.json:
  "Measure first, then decide"). known-wrong is enforced per (commodity, store) on the product name: a row is
  blocked when its KwNorm form, or its KwCore form (trailing size clause stripped), equals the norm or core of a
  ruled name (Test-KnownWrong in known-wrong-lib.ps1, which compare-deals runs on every build). So every new SKU
  of an already-ruled shape pages again. Should a ruling carry a PATTERN as well as a name? This probe derives the
  pattern a pattern-keyed ruling would most plausibly use, three ways, and counts what each would ALSO block.

  THE BASELINE ("D0", what enforcement does today): Test-KnownWrong semantics, norm-or-core against norm-or-core.
  THE THREE DERIVATIONS. Each maps a product name to a KEY; a candidate row matches a ruling when it is at the
  ruling's store and its key equals the key of one of the ruling's names. An empty key is no pattern.
    D1 size-count   KwNorm tokens with every run of numbers that is followed by a unit token removed together with
                    those unit tokens ("8 5 oz pouch", "4 lb tray", "12 pk"), a joined size token removed ("32oz",
                    "8ct"), and a bare trailing number removed. Every other token is kept, so "73" in "73 lean" and
                    a flavour word both survive. The narrowest generalisation: same product, other size or count.
    D2 flavour      D1, then every token in $FlavourLexicon below removed (flavours, scents, "flavored",
                    "original", "classic"...). Same product line, any size and any flavour. The lexicon is a
                    hard-coded list and that is itself a finding: flavour generalisation needs one.
    D3 shape        the first three KwNorm tokens, the SHAPE add-known-wrong.ps1 already uses to refuse a second
                    ruling of a shape (Get-KwShape, Brad's ruling B on queue 2026-09-21-7d64a6). The broadest.

  SCOPE OF AN EXTRA ROW. A ruling acts only on its own (commodity, store) cell, so an extra row counts IN SCOPE when
  it is at the ruling's store and either (a) the current commodities.json rules, first-match-wins include then
  exclude (the semantics audit-semantic-identity.ps1 uses for its corpus), send its name to the ruling's
  commodity, or (b) it sat in that commodity's cell at that store on any dated board. Store-wide name matches under
  other commodities are counted beside it as an upper bound and never listed.

  REVIEWED. For each in-scope extra row: is its KwNorm name, bounded by spaces, inside any normalised string value
  of known-wrong.json (split into same-scope, reversed same-scope and elsewhere), match-verdicts.json,
  discovery-verdicts.json, verdict-suppressions.json, coverage-gap-allowlist.json, multipack-allowlist.json, any
  triage-plans\*.json, or the triage queue (-TriageQueue, gitignored). A mention in a plan counts as a look, which
  OVERSTATES review; a review that named the product by a shorter spelling is missed, which UNDERSTATES it.

  ACCEPTANCE BARS, written 2026-09-25 BEFORE THE FIRST RUN, in the metric's own units:
    BAR-SAFE   a derivation is fit to key a ruling only if, over all ACTIVE rulings, it blocks 0 in-scope extra rows
               that no record shows anyone reviewed, AND 0 extra rows that are a published cell of the ruling's own
               commodity and store on the newest board and are not already ruled in that scope.
    BAR-VALUE  it covers at least 2 of the 3 motivating 2026-09-20 re-pages (two Ben's Original Ready Rice flavour
               SKUs on cooked-jasmine-rice at Baker's, one Stayfree SKU). A Ben's SKU is covered when the OTHER Ben's
               ruling's pattern matches it; a Stayfree SKU when any active ruling at its store, in scope, matches it.
  Both must pass. Nothing was tuned after the run; the lexicon and the three derivations are the first plausible
  versions, and no other variant was tried.

  SCOPE OF A CLEAN REPORT: none - this is a report, it does not pass or fail anything. Its counts are UNSOUND for
  products the captures never saw (a pattern could block a SKU that has not been listed yet, which is the point of a
  pattern, and no corpus can count those) and INCOMPLETE where the review search reads a mention as a look.

  Usage:  probe-known-wrong-patterns.ps1 [-Root <grocery dir>] [-TriageQueue <path>] [-OutRows <jsonl>] [-OutSummary <json>]
          probe-known-wrong-patterns.ps1 -SelfTest
  Exit:   0 measured, 3 BLIND (no board or no capture could be read). Last line: PROBE-KNOWN-WRONG-PATTERNS-COMPLETE.
#>
[CmdletBinding()]
param(
  [string]$Root,
  [string]$TriageQueue,
  [string]$OutRows,
  [string]$OutSummary,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = $PSScriptRoot }
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile (known-wrong-lib loads it too; named here so the dependency is visible)
. (Join-Path $PSScriptRoot 'known-wrong-lib.ps1')   # KwNorm, KwCore, $KW_UNIT_TOKENS: the production normaliser

$script:UnitSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach ($u in $KW_UNIT_TOKENS) { [void]$script:UnitSet.Add($u) }
$script:JoinedSizeRx = '^[0-9]+(' + (($KW_UNIT_TOKENS | Sort-Object Length -Descending) -join '|') + ')$'

$FlavourLexicon = @(
  'flavor','flavors','flavored','flavour','flavours','flavoured','scent','scents','scented','unscented','fragrance','free',
  'original','classic','regular','plain','traditional','homestyle','variety',
  'vanilla','chocolate','strawberry','cherry','apple','lemon','lime','orange','grape','peach','mango','pineapple','coconut',
  'banana','blueberry','raspberry','berry','berries','mixed','cinnamon','maple','honey','caramel','mint','peppermint','pumpkin',
  'spice','spiced','garlic','herb','herbs','onion','butter','buttery','cheddar','cheese','ranch','bbq','barbecue','buffalo',
  'teriyaki','cilantro','roasted','chicken','beef','pork','bacon','sausage','tomato','basil','pepper','jalapeno','chipotle',
  'sweet','spicy','hot','mild','salted','unsalted','smoked','seasoned','italian','mexican','southwest','fruit','tropical',
  'watermelon','lavender','fresh','clean','meadow','linen','breeze','spring','ocean','rain','sea','salt','sour','cream'
)
$script:FlavourSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach ($f in $FlavourLexicon) { [void]$script:FlavourSet.Add($f) }

function Get-SizeFreeTokens([string]$Norm) {
  $t = @(($Norm + '') -split ' ' | Where-Object { $_ })
  $keep = New-Object System.Collections.Generic.List[string]
  $i = 0
  while ($i -lt $t.Count) {
    if ($t[$i] -match '^[0-9]+$') {
      $j = $i
      while ($j -lt $t.Count -and ($t[$j] -match '^[0-9]+$' -or $t[$j] -eq 'x')) { $j++ }
      if ($j -lt $t.Count -and $script:UnitSet.Contains($t[$j])) {
        while ($j -lt $t.Count -and $script:UnitSet.Contains($t[$j])) { $j++ }
        $i = $j; continue
      }
      if ($j -ge $t.Count) { $i = $j; continue }
      for ($k = $i; $k -lt $j; $k++) { $keep.Add($t[$k]) }
      $i = $j; continue
    }
    if ($t[$i] -match $script:JoinedSizeRx) { $i++; continue }
    $keep.Add($t[$i]); $i++
  }
  return ,($keep.ToArray())
}
function Get-PatternKey([string]$Derivation, [string]$Raw) {
  $n = KwNorm $Raw
  if (-not $n) { return '' }
  switch ($Derivation) {
    'D1' { return ((Get-SizeFreeTokens $n) -join ' ') }
    'D2' { $toks = Get-SizeFreeTokens $n; return ((@($toks | Where-Object { -not $script:FlavourSet.Contains($_) })) -join ' ') }
    'D3' { $w = @($n -split ' ' | Where-Object { $_ }); if ($w.Count -lt 3) { return '' }; return ($w[0] + ' ' + $w[1] + ' ' + $w[2]) }
    default { throw "unknown derivation: $Derivation" }
  }
}
# D0: Test-KnownWrong semantics - norm-or-core of the row against norm-or-core of the ruled names.
function Get-D0Set($Names) {
  $s = @{}
  foreach ($nm in @($Names)) { $nn = KwNorm ([string]$nm); if ($nn) { $s[$nn] = $true; $cc = KwCore $nn; if ($cc) { $s[$cc] = $true } } }
  return $s
}
function Test-D0([hashtable]$Set, [string]$Norm) {
  if (-not $Norm) { return $false }
  if ($Set.ContainsKey($Norm)) { return $true }
  $cc = KwCore $Norm
  return [bool]($cc -and $Set.ContainsKey($cc))
}
function Get-StringValues($Obj, $Acc) {
  if ($null -eq $Obj) { return }
  if ($Obj -is [string]) { [void]$Acc.Add($Obj); return }
  if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [System.Management.Automation.PSCustomObject])) { foreach ($x in $Obj) { Get-StringValues $x $Acc }; return }
  if ($Obj -is [System.Management.Automation.PSCustomObject]) { foreach ($p in $Obj.PSObject.Properties) { [void]$Acc.Add([string]$p.Name); Get-StringValues $p.Value $Acc } }
}
function New-ReviewText([string[]]$Values) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($v in $Values) { $nv = KwNorm $v; if ($nv) { [void]$sb.Append("`n ").Append($nv).Append(" `n") } }
  return $sb.ToString()
}
function Test-ReviewText([string]$Text, [string]$Norm) {
  if (-not $Norm) { return $false }
  return ($Text.IndexOf(' ' + $Norm + ' ', [StringComparison]::Ordinal) -ge 0)
}

if ($SelfTest) {
  $bad = 0; $ran = 0
  function _T([string]$Label, [bool]$Ok) { $script:ran++; if ($Ok) { Write-Output ('  ok   ' + $Label) } else { Write-Output ('  FAIL ' + $Label); $script:bad++ } }
  $cil = 'Ben''s Original Ready Rice Cilantro Lime Flavored Rice, Easy Dinner Side, 8.5 oz Pouch'
  $chk = 'Ben''s Original Ready Rice Roasted Chicken Flavored Rice, Easy Dinner Side, 8.8 oz Pouch'
  $jas = 'Ben''s Original Ready Rice Jasmine Rice, Easy Dinner Side, 8.5 oz Pouch'
  try {
    _T 'MUST FIRE  D2 folds the two Ben''s flavour SKUs onto one key' ((Get-PatternKey 'D2' $cil) -eq (Get-PatternKey 'D2' $chk))
    _T 'MUST NOT FIRE  D1 keeps the flavour, so the two Ben''s SKUs differ' ((Get-PatternKey 'D1' $cil) -ne (Get-PatternKey 'D1' $chk))
    _T 'MUST NOT FIRE  D2 keeps jasmine, so plain Ben''s Jasmine is not the flavoured key' ((Get-PatternKey 'D2' $jas) -ne (Get-PatternKey 'D2' $cil))
    _T 'MUST FIRE  D3 puts Ben''s Jasmine on the flavoured shape (the hazard it measures)' ((Get-PatternKey 'D3' $jas) -eq (Get-PatternKey 'D3' $cil))
    _T 'MECHANISM  D3 is add-known-wrong''s shape, first three words' ((Get-PatternKey 'D3' $cil) -eq 'bens original ready')
    _T 'CLEAN TWIN  D1 strips a decimal size and its unit: 8.5 oz Pouch vs 17.3 oz Pouch' ((Get-PatternKey 'D1' 'Acme Rice, 8.5 oz Pouch') -eq (Get-PatternKey 'D1' 'Acme Rice 17.3 oz Pouch'))
    _T 'CLEAN TWIN  D1 strips a joined size token and a pack count' ((Get-PatternKey 'D1' 'Acme Cola 12pk') -eq (Get-PatternKey 'D1' 'Acme Cola 24 Count'))
    _T 'MUST NOT FIRE  D1 keeps a lean percentage: 73% vs 93% ground beef differ' ((Get-PatternKey 'D1' 'Ground Beef 73% Lean/27% Fat, 4 lb Tray') -ne (Get-PatternKey 'D1' 'Ground Beef 93% Lean/7% Fat, 4 lb Tray'))
    _T 'MUST FIRE  D1 folds the 4 lb and 2 lb trays of one lean ratio' ((Get-PatternKey 'D1' 'Ground Beef 73% Lean/27% Fat, 4 lb Tray') -eq (Get-PatternKey 'D1' 'Ground Beef 73% Lean/27% Fat, 2 lb Tray'))
    $d0 = Get-D0Set @('Acme Beans 15 oz')
    _T 'CLEAN TWIN  D0 is Test-KnownWrong: the core form matches a new trailing size' (Test-D0 $d0 (KwNorm 'Acme Beans 29 oz'))
    _T 'MUST NOT FIRE  D0 does not match a different flavour' (-not (Test-D0 $d0 (KwNorm 'Acme Chili Beans 15 oz')))
    $txt = New-ReviewText @('ruled: Bens Rice Pilaf is wrong', 'other')
    _T 'MUST FIRE  review text finds a name bounded by spaces' (Test-ReviewText $txt (KwNorm 'Ben''s Rice Pilaf'))
    _T 'MUST NOT FIRE  review text does not match a name inside a longer word' (-not (Test-ReviewText $txt (KwNorm 'ens Rice')))
    _T 'MUST NOT FIRE  review text does not match across two separate values' (-not (Test-ReviewText (New-ReviewText @('alpha beta','gamma')) 'beta gamma'))
  } catch { Write-Output ('  FAIL a case threw: ' + $_.Exception.Message); $bad++ }
  $want = 14
  if ($ran -ne $want) { Write-Output ("  FAIL ran $ran case(s), the literal list holds $want"); $bad++ }
  if ($bad -eq 0) { Write-Output ("probe-known-wrong-patterns SELF-TEST PASS ($ran cases)"); exit 0 }
  Write-Output ("probe-known-wrong-patterns SELF-TEST FAIL ($bad of $ran)"); exit 1
}

# ================================================================ the measurement
$sw = [Diagnostics.Stopwatch]::StartNew()
$outDir = Join-Path $Root 'out'
$repo = Split-Path $Root -Parent
if (-not $OutRows)    { $OutRows    = Join-Path $repo 'design\MEASURE-known-wrong-pattern-rulings-2026-09-25.rows.jsonl' }
if (-not $OutSummary) { $OutSummary = Join-Path $repo 'design\MEASURE-known-wrong-pattern-rulings-2026-09-25.summary.json' }
$inputs = New-Object System.Collections.Generic.List[string]

# ---- rulings
$kwPath = Join-Path $Root 'known-wrong.json'
$kwDoc = Read-JsonFile $kwPath; [void]$inputs.Add($kwPath)
$entries = @($kwDoc.entries | Where-Object { $_ })
function Test-Active($e) { $p = $e.PSObject.Properties; return -not ($p['reversed_on'] -and ([string]$e.reversed_on).Trim() -and $p['reversed_by'] -and ([string]$e.reversed_by).Trim()) }

# ---- rules (first-match-wins include, then exclude), for the in-scope test
$comPath = Join-Path $Root 'commodities.json'
$coms = Read-JsonFile $comPath; [void]$inputs.Add($comPath)
$rx = New-Object System.Collections.Generic.List[object]; $exc = @{}
foreach ($c in $coms) {
  foreach ($p in @($c.include)) { if ($p) { $rx.Add([pscustomobject]@{ id = [string]$c.id; r = [regex]::new([string]$p, 'IgnoreCase') }) } }
  $l = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($c.exclude)) { if ($p) { $l.Add([regex]::new([string]$p, 'IgnoreCase')) } }
  $exc[[string]$c.id] = $l
}
$ruleCache = @{}
function Get-RuleMatch([string]$Name) {
  if ($ruleCache.ContainsKey($Name)) { return $ruleCache[$Name] }
  $hit = ''
  foreach ($e in $rx) {
    if ($e.r.IsMatch($Name)) {
      $isBad = $false
      foreach ($xp in $exc[$e.id]) { if ($xp.IsMatch($Name)) { $isBad = $true; break } }
      if (-not $isBad) { $hit = $e.id; break }
    }
  }
  $ruleCache[$Name] = $hit
  return $hit
}

# ---- corpus: every (store, KwNorm name) in every capture file and every dated board cell
$corpus = @{}          # store|norm -> @{ store; norm; raw; files }
function Add-CorpusRow([string]$Store, [string]$Raw, [string]$From) {
  if (-not $Store -or -not $Raw) { return }
  $n = KwNorm $Raw; if (-not $n) { return }
  $k = $Store + '|' + $n
  if (-not $corpus.ContainsKey($k)) { $corpus[$k] = @{ store = $Store; norm = $n; raw = $Raw; first = $From; last = $From; seen = 0 } }
  $corpus[$k].seen++; $corpus[$k].last = $From
}
$capFiles = New-Object System.Collections.Generic.List[object]
foreach ($pat in @('regular\*-regular-*.json','ads-*.json','*-deals-*.json','sams\sams-deals-*.json','fareway\fareway-deals-*.json','bakers\bakers-deals-*.json')) {
  foreach ($f in @(Get-ChildItem (Join-Path $outDir $pat) -File -ErrorAction SilentlyContinue)) { $capFiles.Add($f) }
}
$capRead = 0; $capBad = New-Object System.Collections.Generic.List[string]
foreach ($f in ($capFiles | Sort-Object FullName -Unique)) {
  try { $d = Read-JsonFile $f.FullName } catch { [void]$capBad.Add($f.Name); continue }
  $capRead++; [void]$inputs.Add($f.FullName)
  $fst = [string]$d.store
  foreach ($x in @($d.deals)) { if ($x) { $st = [string]$x.store; if (-not $st) { $st = $fst }; Add-CorpusRow $st ([string]$x.item) $f.Name } }
}
$boardFiles = @(Get-ChildItem (Join-Path $outDir 'comparison-*.json') -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name)
$everCell = @{}; $newestCell = @{}
$newest = if ($boardFiles.Count) { $boardFiles[-1].Name } else { '' }
foreach ($b in $boardFiles) {
  $bd = Read-JsonFile $b.FullName; [void]$inputs.Add($b.FullName)
  foreach ($r in @($bd.comparison)) {
    $id = [string]$r.id; if (-not $id) { continue }
    foreach ($s in @($r.stores)) {
      $it = [string]$s.item; if (-not $it) { continue }
      $st = [string]$s.store; $n = KwNorm $it
      Add-CorpusRow $st $it $b.Name
      $everCell[$id + '|' + $st + '|' + $n] = $true
      if ($b.Name -eq $newest) { $newestCell[$id + '|' + $st + '|' + $n] = $true }
    }
  }
}
if ($boardFiles.Count -eq 0 -or $capRead -eq 0) {
  Write-Output ("PROBE-KNOWN-WRONG-PATTERNS BLIND: read $($boardFiles.Count) dated board(s) and $capRead capture file(s) under $outDir. A worktree with no seeded board is blind; run ops\seed-worktree.ps1 -Target <worktree>. Nothing was measured, which is not zero.")
  Write-Output 'PROBE-KNOWN-WRONG-PATTERNS-COMPLETE blind=no-corpus'
  exit 3
}
$byStore = @{}
foreach ($v in $corpus.Values) { if (-not $byStore.ContainsKey($v.store)) { $byStore[$v.store] = New-Object System.Collections.Generic.List[object] }; $byStore[$v.store].Add($v) }

# ---- per-derivation key index: derivation|store|key -> list of corpus rows
$index = @{}
foreach ($dv in @('D1','D2','D3')) {
  foreach ($v in $corpus.Values) {
    $key = Get-PatternKey $dv $v.raw
    if (-not $key) { continue }
    $ik = $dv + '|' + $v.store + '|' + $key
    if (-not $index.ContainsKey($ik)) { $index[$ik] = New-Object System.Collections.Generic.List[object] }
    $index[$ik].Add($v)
  }
}

# ---- review ledgers
$reviewSources = New-Object System.Collections.Generic.List[object]
function Add-ReviewSource([string]$Label, [string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $acc = New-Object System.Collections.Generic.List[string]
  try { Get-StringValues (Read-JsonFile $Path) $acc } catch { return }
  [void]$inputs.Add($Path)
  $reviewSources.Add([pscustomobject]@{ label = $Label; text = (New-ReviewText $acc.ToArray()) })
}
foreach ($pair in @(@('match-verdicts','match-verdicts.json'), @('discovery-verdicts','discovery-verdicts.json'), @('verdict-suppressions','verdict-suppressions.json'), @('coverage-gap-allowlist','coverage-gap-allowlist.json'), @('multipack-allowlist','multipack-allowlist.json'))) {
  Add-ReviewSource $pair[0] (Join-Path $Root $pair[1])
}
foreach ($f in @(Get-ChildItem (Join-Path $Root 'triage-plans\*.json') -File -ErrorAction SilentlyContinue | Sort-Object Name)) { Add-ReviewSource 'triage-plans' $f.FullName }
if ($TriageQueue) { Add-ReviewSource 'triage-queue' $TriageQueue }
# known-wrong itself, by scope
$kwSame = @{}; $kwRev = @{}; $kwAny = @{}
foreach ($e in $entries) {
  $sc = [string]$e.commodity + '|' + [string]$e.store
  $act = Test-Active $e
  foreach ($nm in @($e.names)) {
    $nn = KwNorm ([string]$nm); if (-not $nn) { continue }
    $kwAny[$nn] = $true
    if ($act) { $kwSame[$sc + '|' + $nn] = [string]$e.key } else { $kwRev[$sc + '|' + $nn] = [string]$e.key }
  }
}

# ---- one row per ruling per derivation
$rows = New-Object System.Collections.Generic.List[object]
foreach ($e in $entries) {
  $cid = [string]$e.commodity; $st = [string]$e.store; $sc = $cid + '|' + $st
  $names = @($e.names | Where-Object { $_ })
  $d0 = Get-D0Set $names
  $storeRows = if ($byStore.ContainsKey($st)) { $byStore[$st] } else { $null }
  $exact = 0; $exactScope = 0; $exactNewest = 0
  if ($storeRows) {
    foreach ($v in $storeRows) {
      if (Test-D0 $d0 $v.norm) {
        $exact++
        if ($everCell.ContainsKey($sc + '|' + $v.norm) -or (Get-RuleMatch $v.raw) -eq $cid) { $exactScope++ }
        if ($newestCell.ContainsKey($sc + '|' + $v.norm)) { $exactNewest++ }
      }
    }
  }
  foreach ($dv in @('D1','D2','D3')) {
    $keys = @{}
    foreach ($nm in $names) { $kk = Get-PatternKey $dv ([string]$nm); if ($kk) { $keys[$kk] = $true } }
    $extraStore = 0
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($kk in $keys.Keys) {
      $ik = $dv + '|' + $st + '|' + $kk
      if (-not $index.ContainsKey($ik)) { continue }
      foreach ($v in $index[$ik]) {
        if (Test-D0 $d0 $v.norm) { continue }
        $extraStore++
        $rm = Get-RuleMatch $v.raw
        $ever = $everCell.ContainsKey($sc + '|' + $v.norm)
        if (-not ($ever -or $rm -eq $cid)) { continue }
        $by = New-Object System.Collections.Generic.List[string]
        $same = if ($kwSame.ContainsKey($sc + '|' + $v.norm)) { $kwSame[$sc + '|' + $v.norm] } else { '' }
        if ($same) { [void]$by.Add('known-wrong:same-scope') }
        if ($kwRev.ContainsKey($sc + '|' + $v.norm)) { [void]$by.Add('known-wrong:REVERSED-same-scope') }
        if (-not $same -and $kwAny.ContainsKey($v.norm)) { [void]$by.Add('known-wrong:elsewhere') }
        foreach ($rs in $reviewSources) { if (-not $by.Contains($rs.label) -and (Test-ReviewText $rs.text $v.norm)) { [void]$by.Add($rs.label) } }
        $list.Add([ordered]@{
          name = $v.raw; norm = $v.norm; rule_match = $rm; ever_on_board_in_scope = $ever
          on_newest_board_in_scope = $newestCell.ContainsKey($sc + '|' + $v.norm)
          already_ruled_same_scope = $same; reviewed_by = @($by.ToArray()); reviewed = ($by.Count -gt 0)
          first_seen_in = $v.first; last_seen_in = $v.last
        })
      }
    }
    $arr = @($list.ToArray())
    $rows.Add([ordered]@{
      ruling = [string]$e.key; commodity = $cid; store = $st; verdict = [string]$e.verdict; active = (Test-Active $e)
      ruled_on = [string]$e.ruled_on; derivation = $dv; patterns = @($keys.Keys | Sort-Object)
      store_rows_in_corpus = $(if ($storeRows) { $storeRows.Count } else { 0 })
      exact_rows = $exact; exact_rows_in_scope = $exactScope; exact_on_newest_board = $exactNewest
      extra_rows_store_wide = $extraStore; extra_rows_in_scope = $arr.Count
      extra_already_ruled_same_scope = @($arr | Where-Object { $_.already_ruled_same_scope }).Count
      extra_reviewed = @($arr | Where-Object { $_.reviewed }).Count
      extra_never_reviewed = @($arr | Where-Object { -not $_.reviewed }).Count
      extra_on_newest_board_unruled = @($arr | Where-Object { $_.on_newest_board_in_scope -and -not $_.already_ruled_same_scope }).Count
      extra = $arr
    })
  }
}

# ---- motivating cases
$benA = 'cooked-jasmine-rice|Bakers|bens-original-ready-rice-cilantro-lime-flavored'
$benB = 'cooked-jasmine-rice|Bakers|bens-original-ready-rice-roasted-chicken-flavore'
$eA = $entries | Where-Object { $_.key -eq $benA } | Select-Object -First 1
$eB = $entries | Where-Object { $_.key -eq $benB } | Select-Object -First 1
$motiv = New-Object System.Collections.Generic.List[object]
foreach ($dv in @('D1','D2','D3')) {
  $ka = if ($eA) { Get-PatternKey $dv ([string]$eA.names[0]) } else { '' }
  $kb = if ($eB) { Get-PatternKey $dv ([string]$eB.names[0]) } else { '' }
  $stay = New-Object System.Collections.Generic.List[object]
  foreach ($v in $corpus.Values) {
    if ($v.norm -notmatch '\bstayfree\b') { continue }
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($e in $entries) {
      if (-not (Test-Active $e) -or [string]$e.store -ne $v.store) { continue }
      $vk = Get-PatternKey $dv $v.raw; if (-not $vk) { continue }
      foreach ($nm in @($e.names)) { if ((Get-PatternKey $dv ([string]$nm)) -eq $vk) { [void]$hits.Add([string]$e.key); break } }
    }
    $stay.Add([ordered]@{ store = $v.store; name = $v.raw; rule_match = (Get-RuleMatch $v.raw); rulings_whose_pattern_matches = @($hits.ToArray()) })
  }
  $motiv.Add([ordered]@{
    derivation = $dv; ben_cilantro_key = $ka; ben_chicken_key = $kb
    ben_second_covered_by_first = [bool]($ka -and $ka -eq $kb)
    stayfree_rows = @($stay.ToArray())
    stayfree_covered = (@($stay | Where-Object { $_.rulings_whose_pattern_matches.Count -gt 0 }).Count -gt 0)
  })
}

# ---- totals, derived from the rows
$active = @($rows | Where-Object { $_.active })
$tot = New-Object System.Collections.Generic.List[object]
foreach ($dv in @('D1','D2','D3')) {
  $r = @($active | Where-Object { $_.derivation -eq $dv })
  $ex = @($r | ForEach-Object { $row = $_; foreach ($x in $row.extra) { [pscustomobject]@{ scope = $row.commodity + '|' + $row.store; x = $x } } })
  $distinct = @{}; $distinctNever = @{}; $distinctNewest = @{}; $distinctSame = @{}
  foreach ($y in $ex) {
    $dk = $y.scope + '|' + $y.x.norm; $distinct[$dk] = $true
    if (-not $y.x.reviewed) { $distinctNever[$dk] = $true }
    if ($y.x.on_newest_board_in_scope -and -not $y.x.already_ruled_same_scope) { $distinctNewest[$dk] = $true }
    if ($y.x.already_ruled_same_scope) { $distinctSame[$dk] = $true }
  }
  $m = $motiv | Where-Object { $_.derivation -eq $dv }
  $covered = 0; if ($m.ben_second_covered_by_first) { $covered += 2 }; if ($m.stayfree_covered) { $covered += 1 }
  $safe = ($distinctNever.Count -eq 0 -and $distinctNewest.Count -eq 0)
  $tot.Add([ordered]@{
    derivation = $dv; active_rulings = $r.Count
    rulings_with_no_pattern = @($r | Where-Object { $_.patterns.Count -eq 0 }).Count
    rulings_whose_store_has_no_corpus = @($r | Where-Object { $_.store_rows_in_corpus -eq 0 }).Count
    rulings_seen_by_exact_name = @($r | Where-Object { $_.exact_rows -gt 0 }).Count
    rulings_blocking_extra_in_scope = @($r | Where-Object { $_.extra_rows_in_scope -gt 0 }).Count
    rulings_blocking_never_reviewed = @($r | Where-Object { $_.extra_never_reviewed -gt 0 }).Count
    extra_in_scope_row_sum = $(($r | ForEach-Object { [int]$_.extra_rows_in_scope } | Measure-Object -Sum).Sum)
    extra_in_scope_distinct = $distinct.Count
    extra_distinct_already_ruled_same_scope = $distinctSame.Count
    extra_distinct_never_reviewed = $distinctNever.Count
    extra_distinct_published_newest_unruled = $distinctNewest.Count
    extra_store_wide_row_sum = $(($r | ForEach-Object { [int]$_.extra_rows_store_wide } | Measure-Object -Sum).Sum)
    motivating_covered_of_3 = $covered
    bar_safe = $safe; bar_value = ($covered -ge 2); fit = ($safe -and $covered -ge 2)
  })
}

# ---- write
$lines = New-Object System.Collections.Generic.List[string]
foreach ($row in $rows) { $lines.Add(($row | ConvertTo-Json -Depth 6 -Compress)) }
[IO.File]::WriteAllText($OutRows, (($lines.ToArray() -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
# input fingerprint: every file read, with its git blob id
$blobs = @()
# Paths go to git as ARGUMENTS, never through a PS 5.1 pipe: piping to a native exe prepends a BOM to the first
# line, so --stdin-paths read "<BOM>C:\...commodities.json", died on it and hashed nothing (first run, 2026-09-25).
$uniq = @($inputs | Sort-Object -Unique)
$ids = New-Object System.Collections.Generic.List[string]
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try {
  for ($s = 0; $s -lt $uniq.Count; $s += 40) {
    $chunk = @($uniq[$s..([Math]::Min($s + 39, $uniq.Count - 1))])
    $got = @(& git hash-object -- $chunk)
    if ($LASTEXITCODE -ne 0 -or $got.Count -ne $chunk.Count) { foreach ($c in $chunk) { $ids.Add('') } } else { foreach ($g in $got) { $ids.Add(([string]$g).Trim()) } }
  }
} finally { $ErrorActionPreference = $prev }
for ($i = 0; $i -lt $uniq.Count; $i++) {
  $rel = $uniq[$i]; if ($rel.StartsWith($repo, [StringComparison]::OrdinalIgnoreCase)) { $rel = $rel.Substring($repo.Length).TrimStart('\') }
  $blobs += [ordered]@{ path = $rel; blob = $ids[$i] }
}
$unhashed = @($blobs | Where-Object { -not $_.blob }).Count
$fp = [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes((($blobs | ForEach-Object { $_.path + ' ' + $_.blob }) -join "`n")))).Replace('-','').ToLower()
$summary = [ordered]@{
  generated = (Get-Date).ToString('s'); harness = 'grocery/probe-known-wrong-patterns.ps1'
  rulings = $entries.Count; active_rulings = @($entries | Where-Object { Test-Active $_ }).Count
  corpus_rows = $corpus.Count; capture_files_read = $capRead; capture_files_unreadable = @($capBad.ToArray())
  dated_boards = $boardFiles.Count; newest_board = $newest; first_board = $boardFiles[0].Name
  review_sources = @($reviewSources | Group-Object label | ForEach-Object { [ordered]@{ label = $_.Name; files = $_.Count } })
  flavour_lexicon = $FlavourLexicon
  totals = @($tot.ToArray()); motivating = @($motiv.ToArray())
  input_fingerprint_sha256 = $fp; inputs_unhashed = $unhashed; inputs = $blobs; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
}
[IO.File]::WriteAllText($OutSummary, (($summary | ConvertTo-Json -Depth 8) + "`n"), (New-Object Text.UTF8Encoding($false)))
foreach ($t in $tot) {
  Write-Output ("{0}: {1} of {2} active rulings block >=1 extra in-scope row; {3} distinct extra rows ({4} already ruled same scope, {5} never reviewed, {6} published on {7} and unruled); motivating covered {8} of 3; BAR-SAFE={9} BAR-VALUE={10}" -f $t.derivation, $t.rulings_blocking_extra_in_scope, $t.active_rulings, $t.extra_in_scope_distinct, $t.extra_distinct_already_ruled_same_scope, $t.extra_distinct_never_reviewed, $t.extra_distinct_published_newest_unruled, $newest, $t.motivating_covered_of_3, $t.bar_safe, $t.bar_value)
}
Write-Output ("corpus {0} (store, name) rows from {1} capture file(s) and {2} dated board(s); {3} rulings, rows -> {4}" -f $corpus.Count, $capRead, $boardFiles.Count, $entries.Count, $OutRows)
Write-Output ("PROBE-KNOWN-WRONG-PATTERNS-COMPLETE rulings={0} rows={1} corpus={2} boards={3} captures={4} inputs={5} unhashed={6} fingerprint={7}" -f $entries.Count, $rows.Count, $corpus.Count, $boardFiles.Count, $capRead, $uniq.Count, $unhashed, $fp.Substring(0,12))
exit 0
