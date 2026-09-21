<#
  verify-price-flags.ps1 - put every paging price flag to the STORE, and keep the answer in out\flag-verification.json.

  Brad's design, 2026-09-21 (grocery/triage-plans/plan-2026-09-21-8.json). The rules are in flag-verify-lib.ps1; this
  file is only the I/O around them:
    * the flags: out\guards-<week>.json from sanity-check.ps1, whose flags carry the cell they are about (id, store,
      item, per_unit ...). A flag with no cell fields (a file written before 2026-09-21) cannot be put to a store: it is
      COUNTED as unresolvable and check-ad-cycles keeps paging it the old way.
    * the store's answers: that store's own capture files (stores.json regular_prefix: out\regular\<prefix>-regular-*.json,
      or out\<prefix>\<prefix>-deals-*.json), i.e. the lane's own reads. Nothing here calls a store: a verification
      lookup comes out of each lane's budget by construction, and a lane that was throttled or walled leaves its flags
      PENDING, which is what makes them lead that store's next worklist (capture-policy-lib Get-CaptureWorklist).
    * the ledger: out\flag-verification.json. Only match settles a question; wrong-price / wrong-product stay open while
      the pipeline keeps producing the contradicted claim, and audit-flag-verification.ps1 (a delegated guards audit)
      quarantines those cells.
  Prints, every run, the resolution per store WITH ITS DENOMINATOR and the pending backlog with its oldest age against
  the capture-policy quarter, then VERIFY-PRICE-FLAGS-COMPLETE.

  Exit 0 = ran (whatever the verdicts). 3 = could not evaluate (no board, or no flags file for it). 1 = crashed.
  -CapturesUpTo yyyy-MM-dd restricts the store's answers to capture files dated on or before that day, and -Today sets
  the clock: together they replay a past day (the 30-day measurement in plan-2026-09-21-8.json does exactly that).
  -NoWrite reads and reports without touching the ledger.
#>
[CmdletBinding()]
param([string]$OutDir = '', [string]$BoardFile = '', [string]$GuardsFile = '', [string]$LedgerFile = '', [string]$Today = '',
      [string]$CapturesUpTo = '', [int]$MaxFilesPerStore = 8, [switch]$NoWrite)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repo = Split-Path $root -Parent
. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\atomic-write.ps1')
. (Join-Path $root 'pu-lib.ps1')
. (Join-Path $root 'match-lib.ps1')
. (Join-Path $root 'global-exclude-lib.ps1')
. (Join-Path $root 'flag-verify-lib.ps1')
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $Today) { $Today = (Get-Date).ToString('yyyy-MM-dd') }
if (-not $CapturesUpTo) { $CapturesUpTo = $Today }
$upTo = ConvertTo-TcFvDay $CapturesUpTo
if ($null -eq $upTo) { Write-Output ('BLIND: -CapturesUpTo ' + $CapturesUpTo + ' is not a yyyy-MM-dd date'); Exit-Guard -Name 'verify-price-flags' -Summary 'bad date' -Code 3 }

# ---- the board and its flags -------------------------------------------------------------------------------------
if (-not $BoardFile) {
  $bf = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if ($bf) { $BoardFile = $bf.FullName }
}
if (-not $BoardFile -or -not (Test-Path -LiteralPath $BoardFile)) { Write-Output 'BLIND: no comparison board to verify flags against'; Exit-Guard -Name 'verify-price-flags' -Summary 'no board' -Code 3 }
$week = ([IO.Path]::GetFileNameWithoutExtension($BoardFile)) -replace '^comparison-', ''
if (-not $GuardsFile) { $GuardsFile = Join-Path (Split-Path $BoardFile -Parent) ('guards-' + $week + '.json') }
if (-not (Test-Path -LiteralPath $GuardsFile)) { Write-Output ('BLIND: no flags file ' + (Split-Path $GuardsFile -Leaf) + ' for board ' + (Split-Path $BoardFile -Leaf) + ' - sanity-check has not run over it'); Exit-Guard -Name 'verify-price-flags' -Summary 'no flags' -Code 3 }
$board = Read-JsonFile $BoardFile
$flagsRaw = Read-JsonFile $GuardsFile
$flags = @($flagsRaw | Where-Object { $null -ne $_ })
if (-not $LedgerFile) { $LedgerFile = Join-Path $OutDir $script:TcFlagLedgerName }
$ledger = New-TcFlagLedger
if (Test-Path -LiteralPath $LedgerFile) {
  try { $ledger = Read-JsonFile $LedgerFile } catch { Write-Output ('BLIND: ' + (Split-Path $LedgerFile -Leaf) + ' is unreadable (' + $_.Exception.Message + ') - refusing to start a fresh ledger over it'); Exit-Guard -Name 'verify-price-flags' -Summary 'ledger unreadable' -Code 3 }
}

$paging = @($flags | Where-Object { $script:TcFlagQuietTypes -notcontains [string]$_.type })
$withCell = @($paging | Where-Object { $_.PSObject.Properties['store'] -and [string]$_.store -and [string]$_.id })
$noCell = $paging.Count - $withCell.Count

# ---- the store's answers: that store's own capture files ----------------------------------------------------------
$storesDoc = Read-JsonFile (Join-Path $root 'stores.json')
$prefixOf = @{}
foreach ($s in @($storesDoc.stores)) { if ($s.regular_prefix) { $prefixOf[[string]$s.name] = [string]$s.regular_prefix } }
$openStores = @{}
$entriesNow = ConvertTo-TcLedgerEntries $ledger
foreach ($k in @($entriesNow.Keys)) { $openStores[[string]$entriesNow[$k].store] = $true }
foreach ($f in $withCell) { $openStores[[string]$f.store] = $true }

$rowsByStore = @{}
$filesRead = @{}
foreach ($st in @($openStores.Keys)) {
  $rowsByStore[$st] = @()
  if (-not $prefixOf.ContainsKey($st)) { continue }   # a store stores.json does not know has no capture family: its flags stay pending
  $px = $prefixOf[$st]
  $cands = @()
  $cands += @(Get-ChildItem (Join-Path $OutDir ('regular\' + $px + '-regular-*.json')) -ErrorAction SilentlyContinue)
  $cands += @(Get-ChildItem (Join-Path $OutDir ($px + '\' + $px + '-deals-*.json')) -ErrorAction SilentlyContinue)
  $dated = @($cands | ForEach-Object {
      $m = [regex]::Match($_.BaseName, '(\d{4}-\d{2}-\d{2})$')
      if ($m.Success) { $d = ConvertTo-TcFvDay $m.Groups[1].Value; if ($null -ne $d -and $d -le $upTo) { [pscustomobject]@{ f = $_; d = $d } } }
    } | Sort-Object d -Descending | Select-Object -First $MaxFilesPerStore)
  $keep = New-Object System.Collections.ArrayList
  foreach ($x in $dated) {
    $doc = $null
    try { $doc = Read-JsonFile $x.f.FullName } catch { Write-Output ('  could not read ' + $x.f.Name + ' - its rows are not an answer this run'); continue }
    $rows = if ($doc -is [array]) { $doc } elseif ($doc.PSObject.Properties['deals']) { $doc.deals } else { @() }
    foreach ($r in @($rows)) { if ($null -ne $r) { [void]$keep.Add($r) } }
    $filesRead[$st] = @(@($filesRead[$st]) + $x.f.Name | Where-Object { $_ })
  }
  $rowsByStore[$st] = $keep.ToArray()
}

# ---- identity through the engine's own matcher ------------------------------------------------------------------------
$commodities = Read-JsonFile (Join-Path $root 'commodities.json')
$gex = Get-TcGlobalExclude
$judge = New-TcIdentityJudge -Commodities $commodities -GlobalExclude ([string[]]@($gex))
$unitOf = @{}; foreach ($c in @($commodities)) { $unitOf[[string]$c.id] = [string]$c.unit }

$resolve = {
  param($e)
  $rows = if ($rowsByStore.ContainsKey([string]$e.store)) { $rowsByStore[[string]$e.store] } else { @() }
  $rr = Find-TcStoreReread -Claim $e.claim -Rows $rows
  if ($null -eq $rr.row) { return [pscustomobject]@{ verdict = 'could-not-look'; reason = $rr.why; readings = @() } }
  $a = $rr.row
  $names = Get-TcStoreNames $a
  $idv = Test-TcStoreNameIdentity -Judge $judge -Id ([string]$e.id) -Names $names
  $unit = if ([string]$e.unit) { [string]$e.unit } else { [string]$unitOf[[string]$e.id] }
  $v = Resolve-TcRereadVerdict -Claim $e.claim -Answer $a -Unit $unit -Identity $idv
  $ans = [pscustomobject]@{
    item = [string]$a.item; names = @($names); current_price = [string]$a.current_price; ad_price = [string]$a.ad_price
    size = [string]$a.size; as_of = [string]$a.as_of; product = (Get-TcRowProductKey $a); identity = [string]$idv.verdict
  }
  $v | Add-Member -NotePropertyName answer -NotePropertyValue $ans -Force
  return $v
}

$prevStatus = @{}
foreach ($k in @($entriesNow.Keys)) { $prevStatus[$k] = [string]$entriesNow[$k].status }
$res = Update-TcFlagLedger -Ledger $ledger -Flags $withCell -Board $board -Today $Today -Resolve $resolve
$L = $res.ledger

# ---- the report, with denominators --------------------------------------------------------------------------------
$quarter = 90
try {
  . (Join-Path $root 'capture-policy-lib.ps1')
  $qp = Get-CapturePlan -Store 'Walmart' -Today $Today
  if ($qp -and [int]$qp.QuarterDays -gt 0) { $quarter = [int]$qp.QuarterDays }
} catch { Write-Output ('  the capture-policy quarter could not be read (' + $_.Exception.Message + '); using 90, the rule it states') }
$todayD = ConvertTo-TcFvDay $Today
$open = @(@($L.entries.Keys) | ForEach-Object { $L.entries[$_] })
$closedToday = @(@($L.closed) | Where-Object { [string]$_.closed_at -eq $Today })
$byStore = [ordered]@{}
foreach ($st in @(@($open | ForEach-Object { [string]$_.store }) + @($closedToday | ForEach-Object { [string]$_.store }) | Sort-Object -Unique)) {
  $o = @($open | Where-Object { [string]$_.store -eq $st }); $c = @($closedToday | Where-Object { [string]$_.store -eq $st })
  $byStore[$st] = [ordered]@{
    match = @($c | Where-Object { $_.status -eq 'match' }).Count
    wrong_price = @($o | Where-Object { $_.status -eq 'wrong-price' }).Count
    wrong_product = @($o | Where-Object { $_.status -eq 'wrong-product' }).Count
    pending = @($o | Where-Object { $_.status -eq 'pending' }).Count
    left_unverified = @($c | Where-Object { @('left-board', 'claim-changed') -contains [string]$_.status -and $prevStatus[[string]$_.key] -eq 'pending' }).Count
  }
}
$pend = @($open | Where-Object { $_.status -eq 'pending' })
$oldest = 0; $overdue = 0
foreach ($p in $pend) { $d = ConvertTo-TcFvDay $p.first_flagged; if ($null -ne $d) { $age = [int]($todayD - $d).TotalDays; if ($age -gt $oldest) { $oldest = $age }; if ($age -gt $quarter) { $overdue++ } } }
$newDis = @(@($res.changes) | Where-Object { @('wrong-price', 'wrong-product') -contains [string]$_.change })
$L | Add-Member -NotePropertyName summary -NotePropertyValue ([ordered]@{
    board = (Split-Path $BoardFile -Leaf); flags_file = (Split-Path $GuardsFile -Leaf); paging_flags = $paging.Count; with_cell = $withCell.Count
    no_cell = $noCell; open = $open.Count; pending = $pend.Count; pending_oldest_days = $oldest; pending_overdue = $overdue; quarter_days = $quarter
    new_disagreements = $newDis.Count; by_store = $byStore; files_read = $filesRead
  }) -Force

Write-Output ('flag verification over ' + (Split-Path $GuardsFile -Leaf) + ' (board ' + (Split-Path $BoardFile -Leaf) + ', answers up to ' + $upTo.ToString('yyyy-MM-dd') + '): ' + $paging.Count + ' paging flag(s), ' + $withCell.Count + ' name a cell, ' + $noCell + ' do not (those keep paging the old way)')
foreach ($st in @($byStore.Keys)) {
  $b = $byStore[$st]
  $den = [int]$b.match + [int]$b.wrong_price + [int]$b.wrong_product + [int]$b.pending
  Write-Output ('  {0,-12} {1} of {2} match (closed today), {3} wrong-price, {4} wrong-product, {5} could-not-look/pending; {6} left the board before any re-read' -f $st, $b.match, $den, $b.wrong_price, $b.wrong_product, $b.pending, $b.left_unverified)
}
foreach ($e in @($open | Where-Object { @('wrong-price', 'wrong-product') -contains [string]$_.status })) {
  Write-Output ('  DISAGREES {0} [{1}] ours {2:0.0000}/{3} "{4}" - {5}' -f $e.key, $e.status, [double]$e.claim.per_unit, $e.unit, $e.claim.item, $e.reason)
}
foreach ($e in $pend) { Write-Output ('  pending   {0} since {1}: {2}' -f $e.key, $e.first_flagged, $e.reason) }
Write-Output ('pending backlog: ' + $pend.Count + ' verification(s), oldest ' + $oldest + ' day(s); ' + $overdue + ' past the ' + $quarter + '-day capture-policy quarter')

if (-not $NoWrite) {
  $json = $L | ConvertTo-Json -Depth 12
  [void](Write-TcAtomicFile -Path $LedgerFile -Text $json)
  Write-Output ('ledger written: ' + $LedgerFile)
} else { Write-Output 'ledger NOT written (-NoWrite)' }
Exit-Guard -Name 'verify-price-flags' -Summary ("paging=" + $paging.Count + " cells=" + $withCell.Count + " open=" + $open.Count + " pending=" + $pend.Count + " disagreements=" + @($open | Where-Object { @('wrong-price', 'wrong-product') -contains [string]$_.status }).Count + " new=" + $newDis.Count + " overdue=" + $overdue) -Code 0
