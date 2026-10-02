<#
  audit-crown-identity-shadow.ps1 - step 9 of design/PLAN-zero-alert-days-remainder-2026-09-24.md, SHADOW ONLY.

  Ruling 3, verbatim: "Two independent signals must agree for a crown; 2 weeks in shadow before it refuses anything".
  For every CROWN on the newest comparison board (the stores[] cell of the row's cheapest_store), the first signal is
  the commodity the name rules gave it. The second is the department the STORE's own capture filed the product in,
  translated by grocery/store-department-map.json and judged against aisle-lib.ps1's reviewed expected departments
  (store-department-lib.ps1). Each crown gets one row a day: agree, disagree or no-signal.

  REFUSES NOTHING, CHANGES NOTHING. It reads the board and the captures and writes one gitignored file,
  out\crown-identity-shadow\crown-identity-shadow-<date>.jsonl (a re-run the same day replaces that day's file). The
  enforcement bar is Brad's and is not this script's: a hand-checked sample of at least 30 disagreements, at least 80%
  real wrong products, and no more than 2% of live cells emptied, after 14 days of shadow.

  It also re-reads the family-2 queue cases (store-department-map.json -> watch_cases) on today's captures and on the
  dated file each item cites, so the step's effect on them is visible before enforcement.

  SCOPE OF A CLEAN REPORT: unsound. Walmart, Sam's Club and Aldi capture no category, so every crown there is
  no-signal, and a store word the map does not translate is no-signal too; a report with no disagreement proves nothing
  about those crowns. A disagreement is a candidate, not a finding (incomplete): the expected sets were reviewed on
  Family Fare's shelves, and another store may shelve a right product elsewhere. That is what the 30-row hand check is for.
  WHEN THE PRODUCER STOPS: no board, or a board with no crown, is BLIND (exit 3), never a quiet clean day.

  Exit: 0 the shadow ran (disagreements are data, not failure); 3 BLIND; 1 the audit threw. Last line is the marker.
  Usage: .\audit-crown-identity-shadow.ps1 [-Board <comparison json>] [-OutDir <dir>] [-NoWrite] [-DataRoot <grocery tree>]
         .\audit-crown-identity-shadow.ps1 -SelfTest
#>
# gate-inputs: grocery\audit-crown-identity-shadow.ps1, grocery\store-department-lib.ps1, grocery\aisle-lib.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent drop (audit-arg-binding)
param([string]$Board = '', [string]$OutDir = '', [switch]$NoWrite, [switch]$SelfTest, [string]$DataRoot = '')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$data = if ($DataRoot) { $DataRoot } else { $root }   # -DataRoot: the grocery tree whose map, captures and board are read (the self-test's temp tree)
. (Join-Path (Split-Path $root -Parent) 'lib\json-io.ps1')   # Read-JsonFile, named here though the lib loads it too
. (Join-Path $root 'store-department-lib.ps1')
. (Join-Path (Split-Path $root -Parent) 'lib\atomic-write.ps1')

# One file read as its own store entry, for a case that cites a dated file.
function New-CitedEntry([string]$Root, $Map, [string]$Store, [string]$Rel) {
  $p = Join-Path $Root $Rel
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  $e = @{ by_name = @{}; by_id = @{}; files = @(); rows = 0 }
  if ($p -like '*.jsonl') { Add-FlyerEvidence $e $p; return $e }
  $cfg = $Map.stores.$Store
  if (-not $cfg) { return $null }
  foreach ($r in @((Read-JsonFile $p).deals)) {
    if ($null -eq $r) { continue }
    $e.rows++
    $sig = Get-RowStoreDepts $cfg $r
    if ($sig.raw) { $e.by_name[(Get-StoreRowKey ([string]$r.item))] = $sig }
  }
  $e.files += (Split-Path $p -Leaf)
  return $e
}

# A case name may be the start of a capture name ('... 4 Ea' trimmed in the queue body): exact first, then prefix.
function Find-CaseSignal($Entry, [string]$Product) {
  if (-not $Entry) { return $null }
  $k = Get-StoreRowKey $Product
  foreach ($t in 'by_line', 'by_name') {
    if (-not $Entry.ContainsKey($t)) { continue }
    if ($Entry[$t].ContainsKey($k)) { return $Entry[$t][$k] }
  }
  foreach ($t in 'by_line', 'by_name') {
    if (-not $Entry.ContainsKey($t)) { continue }
    foreach ($kk in $Entry[$t].Keys) { if ($kk.StartsWith($k) -or ($kk.Length -ge 12 -and $k.StartsWith($kk))) { return $Entry[$t][$kk] } }
  }
  return $null
}

function Invoke-CrownShadow([string]$Root, [string]$BoardPath, [string]$Day) {
  $map = Read-StoreDeptMap $Root
  $cat = Get-AisleCategoryMap -Root $Root
  $ix = New-StoreDeptIndex $Root $map
  $doc = Read-JsonFile $BoardPath
  $bname = Split-Path $BoardPath -Leaf
  $rows = New-Object System.Collections.Generic.List[object]
  $crownItem = @{}
  foreach ($r in @($doc.comparison)) {
    if ($null -eq $r -or -not $r.cheapest_store) { continue }
    $cs = [string]$r.cheapest_store
    $c = @($r.stores | Where-Object { [string]$_.store -eq $cs })
    if ($c.Count -eq 0) { continue }
    $c = $c[0]
    $sig = Get-CellStoreSignal $ix $map $cs ([string]$c.item) ([string]$c.link)
    $v = Get-SecondSignalVerdict $cat ([string]$r.id) $sig.depts
    $crownItem[[string]$r.id] = [string]$c.item
    $rows.Add([pscustomobject][ordered]@{ kind = 'crown'; day = $Day; board = $bname; built_at = [string]$doc.built_at
      commodity = [string]$r.id; store = $cs; product = [string]$c.item; per_unit = $c.per_unit; category = $sig.raw
      departments = @($sig.depts); via = $sig.via; verdict = $v.verdict; reason = $v.reason })
  }
  $cases = New-Object System.Collections.Generic.List[object]
  foreach ($w in @($map.watch_cases)) {
    if ($null -eq $w) { continue }
    $stores = if ($w.store) { @([string]$w.store) } else { @($map.stores.PSObject.Properties.Name) }
    $today = $null; $todayStore = ''
    foreach ($s in $stores) { if ($ix.ContainsKey($s)) { $f = Find-CaseSignal $ix[$s] ([string]$w.product); if ($f) { $today = $f; $todayStore = $s; break } } }
    $tv = if ($today) { Get-SecondSignalVerdict $cat ([string]$w.commodity) $today.depts } else { [pscustomobject]@{ verdict = 'no-signal'; reason = 'no capture row of that name carries a store category today' } }
    $cv = $null; $craw = ''
    if ($w.cited) {
      $ce = New-CitedEntry $Root $map ([string]$w.store) ([string]$w.cited)
      $cf = Find-CaseSignal $ce ([string]$w.product)
      if ($cf) { $craw = $cf.raw; $cv = Get-SecondSignalVerdict $cat ([string]$w.commodity) $cf.depts }
      elseif ($ce) { $cv = [pscustomobject]@{ verdict = 'no-signal'; reason = 'the cited file holds no row of that name with a category' } }
      else { $cv = [pscustomobject]@{ verdict = 'no-signal'; reason = 'the cited file is not in this checkout' } }
    }
    $onBoard = ($crownItem.ContainsKey([string]$w.commodity) -and (Get-StoreRowKey $crownItem[[string]$w.commodity]).StartsWith((Get-StoreRowKey ([string]$w.product))))
    $cases.Add([pscustomobject][ordered]@{ kind = 'case'; day = $Day; board = $bname; queue = [string]$w.queue; commodity = [string]$w.commodity
      store = $(if ($todayStore) { $todayStore } else { [string]$w.store }); product = [string]$w.product; crown_today = $onBoard
      category = $(if ($today) { $today.raw } else { '' }); verdict = $tv.verdict; reason = $tv.reason
      cited = [string]$w.cited; cited_category = $craw; cited_verdict = $(if ($cv) { $cv.verdict } else { '' }) })
  }
  return [pscustomobject]@{ board = $bname; built_at = [string]$doc.built_at; rows = $rows.ToArray(); cases = $cases.ToArray() }
}

function Get-ShadowTally($Rows) {
  $t = [ordered]@{}
  foreach ($r in @($Rows)) {
    if (-not $t.Contains($r.store)) { $t[$r.store] = [ordered]@{ crowns = 0; agree = 0; disagree = 0; 'no-signal' = 0 } }
    $t[$r.store].crowns++; $t[$r.store][$r.verdict]++
  }
  return $t
}

if ($SelfTest) {
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cis-st-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  $pass = 0; $fail = 0; $ran = 0; $EXPECTED = 8
  function Check([string]$label, [bool]$ok) { $script:ran++; if ($ok) { $script:pass++; Write-Output ('  ok    ' + $label) } else { $script:fail++; Write-Output ('  FAIL  ' + $label) } }
  function Put([string]$rel, [string]$text) { $p = Join-Path $tmp $rel; New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null; [IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding($false))) }
  try {
    Put 'categories.json' '{"categories":[{"label":"Fruit","key":"fruit","commodities":["lemons"]},{"label":"Dairy & Eggs","key":"dairy","commodities":["milk"]},{"label":"Pasta, Rice & Grains","key":"grains","commodities":["rice"]}]}'
    Put 'store-department-map.json' ('{"stores":{"Family Fare":{"files":["out/regular/family-fare-regular-*.json"],"field":"dept","url_field":"canonical_url","identity":true,"evidence":"familyfare/flyer-link-evidence-*.jsonl"},' +
      '"Tag Mart":{"files":["out/regular/tagmart-regular-*.json"],"field":"store_category","split":" > ","map":{"Dairy":"dairy","Natural & Organic":"","Cleaning Products":"household"}},' +
      '"Plain Mart":{"files":["out/regular/plainmart-regular-*.json"],"field":""}},' +
      '"watch_cases":[{"queue":"Q-1","store":"Family Fare","commodity":"lemons","product":"Glad Drawstring Odor Shield Lemon","cited":"familyfare/flyer-link-evidence-2026-01-01.jsonl"}]}')
    Put 'out/regular/family-fare-regular-2026-01-02.json' '{"deals":[{"item":"Fresh Lemons","dept":"fresh_fruits_vegetables"}]}'
    Put 'out/regular/tagmart-regular-2026-01-02.json' '{"deals":[{"item":"Kroger 2% Milk","product_id":"0001","store_category":"Natural & Organic > Dairy"}]}'
    Put 'out/regular/plainmart-regular-2026-01-02.json' '{"deals":[{"item":"Great Value Long Grain Rice","item_id":"77"}]}'
    # The founding shape of 6fc290: a Weekly Ad line with no shelf path on the board, resolved by the flyer linker to household.
    Put 'familyfare/flyer-link-evidence-2026-01-01.jsonl' '{"kind":"candidate","line":"Glad Drawstring Odor Shield Lemon","product_id":"14841","canonical_url":"https://www.shopfamilyfare.com/shop/household/trash_bags_cans/kitchen/glad/p/14841"}'
    Put 'out/comparison-2026-01-02.json' ('{"built_at":"2026-01-02T08:00","comparison":[' +
      '{"id":"lemons","cheapest_store":"Family Fare","stores":[{"store":"Family Fare","item":"Glad Drawstring Odor Shield Lemon","per_unit":0.2}]},' +
      '{"id":"milk","cheapest_store":"Tag Mart","stores":[{"store":"Tag Mart","item":"Kroger 2% Milk","per_unit":0.03,"link":"https://www.bakersplus.com/p/kroger-2-milk/0001"}]},' +
      '{"id":"rice","cheapest_store":"Plain Mart","stores":[{"store":"Plain Mart","item":"Great Value Long Grain Rice","per_unit":0.05,"link":"https://www.walmart.com/ip/77"}]}]}')
    $res = Invoke-CrownShadow $tmp (Join-Path $tmp 'out\comparison-2026-01-02.json') '2026-01-02'
    $byId = @{}; foreach ($r in @($res.rows)) { $byId[$r.commodity] = $r }
    Check 'MUST FIRE: a household-department product (flyer-linked Glad bags) crowned on lemons reads disagree' ($byId['lemons'].verdict -eq 'disagree' -and $byId['lemons'].via -eq 'ad-line' -and $byId['lemons'].category -eq 'household')
    Check 'MUST NOT FIRE: Tag Mart milk filed Natural & Organic > Dairy reads agree (one allowed tag is agreement)' ($byId['milk'].verdict -eq 'agree' -and $byId['milk'].via -eq 'id')
    Check 'CLEAN TWIN: a Plain Mart crown (no category captured) reads no-signal, never agree' ($byId['rice'].verdict -eq 'no-signal')
    $t = Get-ShadowTally $res.rows
    Check 'CLEAN TWIN: the no-signal crown is COUNTED in the tally (3 crowns, 1 agree, 1 disagree, 1 no-signal)' (@($res.rows).Count -eq 3 -and $t['Plain Mart']['no-signal'] -eq 1 -and $t['Family Fare'].disagree -eq 1 -and $t['Tag Mart'].agree -eq 1)
    $cs = @($res.cases)
    Check 'MUST FIRE: the watch case reads disagree on its cited flyer-link file and is named as today''s crown' ($cs.Count -eq 1 -and $cs[0].cited_verdict -eq 'disagree' -and $cs[0].crown_today -eq $true -and $cs[0].queue -eq 'Q-1')
    Check 'MUST NOT FIRE: a store word the map leaves blank (Natural & Organic alone) is no-signal, not disagree' ((Get-SecondSignalVerdict (Get-AisleCategoryMap -Root $tmp) 'milk' (Get-RowStoreDepts (Read-StoreDeptMap $tmp).stores.'Tag Mart' ([pscustomobject]@{ store_category = 'Natural & Organic' })).depts).verdict -eq 'no-signal')
    # The run itself: exit 0 on a shadow day with a disagreement, exit 3 with no board. Child processes, so the exits are real.
    $me = $MyInvocation.MyCommand.Path; if (-not $me) { $me = Join-Path $root 'audit-crown-identity-shadow.ps1' }
    $o1 = & powershell -NoProfile -File $me -DataRoot $tmp -Board (Join-Path $tmp 'out\comparison-2026-01-02.json') -NoWrite; $rc1 = $LASTEXITCODE
    Check 'a shadow day with a disagreement exits 0 and its last line is the COMPLETE marker (the shadow refuses nothing)' ($rc1 -eq 0 -and ([string]@($o1)[-1]) -like 'CROWN-IDENTITY-SHADOW-COMPLETE*')
    $o2 = & powershell -NoProfile -File $me -DataRoot $tmp -Board (Join-Path $tmp 'out\comparison-1999-01-01.json') -NoWrite; $rc2 = $LASTEXITCODE
    Check 'no board is BLIND: exit 3, never a quiet clean day' ($rc2 -eq 3 -and ([string]@($o2)[-1]) -like '*blind=*')
  } catch {
    $fail++; Write-Output ('  FAIL  the self-test threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($ran -ne $EXPECTED) { $fail++; Write-Output ("  FAIL  ran $ran of $EXPECTED cases - a case did not run") }
  if ($fail -eq 0) { Write-Output ("audit-crown-identity-shadow self-test PASS ($pass of $EXPECTED cases)"); exit 0 }
  Write-Output ("audit-crown-identity-shadow self-test FAIL ($fail failure(s), $pass of $EXPECTED passed)"); exit 1
}

try {
  if (-not $Board) {
    $bf = Get-ChildItem (Join-Path $data 'out\comparison-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^comparison-\d{4}-\d{2}-\d{2}\.json$' } | Sort-Object Name -Descending | Select-Object -First 1
    if ($bf) { $Board = $bf.FullName }
  }
  if (-not $Board -or -not (Test-Path -LiteralPath $Board)) {
    Write-Output ('CROWN-IDENTITY-SHADOW BLIND: no comparison board (' + $Board + '). No crown was judged; this is not a clean day.')
    Write-Output 'CROWN-IDENTITY-SHADOW-COMPLETE crowns=0 blind=no-board'; exit 3
  }
  $day = (Get-Date).ToString('yyyy-MM-dd')
  $res = Invoke-CrownShadow $data $Board $day
  $rows = @($res.rows)
  if ($rows.Count -eq 0) {
    Write-Output ('CROWN-IDENTITY-SHADOW BLIND: ' + $res.board + ' holds no crown. No crown was judged; this is not a clean day.')
    Write-Output 'CROWN-IDENTITY-SHADOW-COMPLETE crowns=0 blind=no-crowns'; exit 3
  }
  Write-Output ("crown identity shadow (step 9, SHADOW ONLY - refuses nothing) on $($res.board), built $($res.built_at)")
  $t = Get-ShadowTally $rows
  foreach ($s in $t.Keys) {
    $x = $t[$s]; $seen = $x.crowns - $x['no-signal']
    Write-Output ("  {0,-12} crowns {1,4}   signal on {2} of {1}   agree {3}   disagree {4}   no-signal {5}" -f $s, $x.crowns, $seen, $x.agree, $x.disagree, $x['no-signal'])
  }
  $ag = @($rows | Where-Object { $_.verdict -eq 'agree' }).Count; $dg = @($rows | Where-Object { $_.verdict -eq 'disagree' }).Count; $ns = @($rows | Where-Object { $_.verdict -eq 'no-signal' }).Count
  Write-Output ("  ALL          crowns {0}   signal on {1} of {0}   agree {2}   disagree {3}   no-signal {4}" -f $rows.Count, ($ag + $dg), $ag, $dg, $ns)
  foreach ($r in @($rows | Where-Object { $_.verdict -eq 'disagree' })) {
    Write-Output ("  DISAGREE  {0} @ {1}: '{2}' - store filed it '{3}' ({4})" -f $r.commodity, $r.store, $r.product, $r.category, $r.reason)
  }
  foreach ($c in @($res.cases)) {
    Write-Output ("  CASE {0}  {1} / {2}: '{3}' today={4}{5}{6}" -f $c.queue, $c.commodity, $c.store, $c.product, $c.verdict, $(if ($c.category) { " ('" + $c.category + "')" } else { '' }), $(if ($c.cited) { "; on $($c.cited)=$($c.cited_verdict)" + $(if ($c.cited_category) { " ('" + $c.cited_category + "')" } else { '' }) } else { '' }))
  }
  if (-not $NoWrite) {
    if (-not $OutDir) { $OutDir = Join-Path $data 'out\crown-identity-shadow' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $lines = @($rows) + @($res.cases) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 }
    $f = Join-Path $OutDir ("crown-identity-shadow-$day.jsonl")
    [void](Write-TcAtomicFile -Path $f -Text (($lines -join "`n") + "`n") -NoBom -NoNewline)
    $days = @(Get-ChildItem (Join-Path $OutDir 'crown-identity-shadow-*.jsonl') | Sort-Object Name)
    Write-Output ("  wrote {0} ({1} crown rows, {2} case rows); shadow days on record: {3}, first {4}" -f $f, $rows.Count, @($res.cases).Count, $days.Count, ($days[0].BaseName -replace '^crown-identity-shadow-', ''))
  }
  Write-Output ("CROWN-IDENTITY-SHADOW-COMPLETE crowns={0} agree={1} disagree={2} nosignal={3} cases={4}" -f $rows.Count, $ag, $dg, $ns, @($res.cases).Count)
  exit 0
} catch {
  Write-Output ('CROWN-IDENTITY-SHADOW threw: ' + $_.Exception.Message)
  Write-Output 'CROWN-IDENTITY-SHADOW-COMPLETE crowns=0 blind=threw'; exit 1
}
