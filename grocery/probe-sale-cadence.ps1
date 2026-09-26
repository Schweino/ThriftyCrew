<#
  probe-sale-cadence.ps1 - how often does a retailer RE-PROMOTE a commodity, per store, read off the dated sale
  windows the comparison boards carry? A REPORT, never a gate, run by hand. Backlog I169.

  WHY IT IS COMMITTED. Brad's 2026-09-12 ruling closing I123: a per-commodity sale cadence may only ever be used
  "as a per-commodity value derived from board history, never as a hand-set constant". A value that must be
  re-derived every time it is used needs a harness that can be re-run, and a rewritten probe is a second harness
  (.claude\rules\measurement.md). I123's figure (480 gaps, median 8, commodity medians 3.5 to 37 days) came from
  a scratch probe with no written definitions and no denominator; this one writes both.

  DEFINITIONS (the acceptance bar in I169 states them first; this is the code that holds them):
    - DATED SALE WINDOW: a board cell with type 'sale' and both ad_from and ad_to parsing as yyyy-MM-dd. One
      window is (commodity id, store, ad_from, ad_to), counted ONCE however many boards carried it - a board
      carries a sale forward day after day, so counting per board would measure the board, not the retailer.
    - UNDATED SALE: a sale cell with no window. Counted per (id, store) and never scored: its only date is the
      board it sat on.
    - EPISODE: one store's windows for one commodity, merged when they overlap or touch (next ad_from at most one
      day after the running ad_to). Without the merge, the same item in two consecutive weekly ads would read as
      a 7-day re-promotion.
    - GAP: days from one episode's START to the next episode's start, same commodity, same store.
    - PAIR CLASS by gap count: none (0 or 1 episode), single (exactly 1 gap, no distribution), formable (2+).
    - SOURCE CLASS of a window: 'shelf' when source_ad names a store search or shelf read (Get-CadenceSourceClass
      holds the pattern), 'unknown' when source_ad is empty, else 'ad'. An episode is 'shelf' only when every
      window in it is shelf-found; a pair is 'shelf' only when every episode is. A shelf-found promotion is the
      only kind the capture worklist could see sooner, because an ad-borne one arrives with the AD ROLLOVER pull.
    - PREDICTION: for a formable pair, its LAST gap is predicted as the median of its earlier gaps.

  SCOPE OF A CLEAN REPORT: UNSOUND in the direction of FEWER gaps. It reads only grocery\out\comparison-*.json,
  which are gitignored, so a worktree or clean checkout without a seed reads nothing and exits 3 BLIND. The
  observable gap is capped by the history span it prints: a commodity whose cycle is longer than about half the
  span can never be formable, so a long cycle reads as BLIND, never as slow. A promotion no board ever carried
  (a store not captured that week, a cell another store won) is invisible.

  -MergeSlackDays (default 1, the bar's definition) widens "touch". Fareway's weekly ad runs Monday to Saturday,
  so one continuous promotion reads as two episodes 7 days apart at slack 1 and as one at slack 2; the item records
  the verdict at both, and the default stays what the bar wrote.

  EXIT: 0 report produced (whatever the verdict); 3 could not evaluate (no board, or no DATED window - one tracked
  board with no ad_from/ad_to fields sits in every clean checkout, so "a board resolved" is not enough). -CasesOut writes one
  JSON row per (commodity, store) pair that had any dated window, and every total printed is derived from those rows.
#>
# The self-test writes its dated boards in temp and loads no library; it never reads grocery\out.
# gate-inputs: grocery\probe-sale-cadence.ps1
[CmdletBinding()]
param(
  [string]$BoardDir = '',
  [string]$CasesOut = '',
  [int]$MergeSlackDays = 1,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $BoardDir) { $BoardDir = Join-Path $here 'out' }   # grocery\out: the boards live beside this probe

# The bar, as written into backlog I169 before any gap was counted. Changing one here without changing the item
# is changing the question after seeing the answer.
$script:BarMinFormablePairs = 20
$script:BarMinCoveragePct   = 10.0
$script:BarMaxMedianErrDays = 3.0
$script:BarWithinDays       = 3

function Get-CadenceSourceClass {
  <# PURE. 'shelf' | 'ad' | 'unknown' for one source_ad string. #>
  param([string]$Source)
  if ([string]::IsNullOrWhiteSpace($Source)) { return 'unknown' }
  if ($Source -match '(?i)shop\.fareway|kroger-api|aisles online|shelf pr') { return 'shelf' }
  return 'ad'
}

function Get-CadenceMedian {
  <# PURE. Median of a numeric array; $null for an empty one. #>
  param([double[]]$Values)
  if (-not $Values -or $Values.Count -eq 0) { return $null }
  $s = @($Values | Sort-Object)
  $m = [int][math]::Floor($s.Count / 2)
  if ($s.Count % 2 -eq 1) { return [double]$s[$m] }
  return ([double]$s[$m - 1] + [double]$s[$m]) / 2.0
}

function Read-CadenceBoards {
  <# Reads every comparison-*.json under $Dir. Returns boards read, their fingerprint, the distinct dated windows
     and the undated sale pairs. Reads files only. #>
  param([string]$Dir)
  $windows = @{}
  $undated = @{}
  $ids = @{}
  $boards = New-Object System.Collections.ArrayList
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $fp = New-Object System.Text.StringBuilder
  if (Test-Path -LiteralPath $Dir) {
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter 'comparison-*.json' -File | Where-Object { $_.Name -match '^comparison-\d{4}-\d{2}-\d{2}\.json$' } | Sort-Object Name)
    foreach ($f in $files) {
      $bytes = [IO.File]::ReadAllBytes($f.FullName)
      [void]$fp.Append($f.Name).Append(':').Append(([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 16)).Append(';')
      $doc = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json
      [void]$boards.Add($f.Name.Substring(11, 10))
      foreach ($c in @($doc.comparison)) {
        $id = [string]$c.id
        if (-not $id) { continue }
        $ids[$id] = $true
        foreach ($s in @($c.stores)) {
          if ([string]$s.type -ne 'sale') { continue }
          $store = [string]$s.store
          $from = [string]$s.ad_from; $to = [string]$s.ad_to
          $okF = $from -match '^\d{4}-\d{2}-\d{2}$'; $okT = $to -match '^\d{4}-\d{2}-\d{2}$'
          if (-not ($okF -and $okT)) { $undated[$id + '|' + $store] = $true; continue }
          $k = $id + '|' + $store + '|' + $from + '|' + $to
          if (-not $windows.ContainsKey($k)) {
            $windows[$k] = [pscustomobject]@{ id = $id; store = $store; from = $from; to = $to; cls = (Get-CadenceSourceClass ([string]$s.source_ad)); src = [string]$s.source_ad }
          } elseif ($windows[$k].cls -ne 'ad' -and (Get-CadenceSourceClass ([string]$s.source_ad)) -eq 'ad') {
            # the same window seen once through the ad: the ad pull would have caught it
            $windows[$k].cls = 'ad'
          }
        }
      }
    }
  }
  $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fp.ToString()))) -replace '-', '').Substring(0, 16).ToLowerInvariant()
  return [pscustomobject]@{ Boards = $boards; Fingerprint = $digest; Windows = @($windows.Values); UndatedPairs = @($undated.Keys); CommodityCount = $ids.Count }
}

function Get-CadenceBlindReason {
  <# PURE. '' when the boards read can answer the question, else why not. One tracked board
     (comparison-2026-08-08.json, older than the ad_from/ad_to fields) sits in every clean checkout, so "a board
     resolved" is not enough: a checkout with no DATED window has nothing to measure. #>
  param($Read)
  if ($Read.Boards.Count -eq 0) { return 'no comparison-<date>.json resolved' }
  if ($Read.Windows.Count -eq 0) { return ('{0} board(s) resolved but not one dated sale window' -f $Read.Boards.Count) }
  return ''
}

function Get-CadencePairs {
  <# PURE. One row per (commodity, store) with its merged episodes, gaps, class and prediction error. #>
  param($Windows, [int]$Slack = 1)
  $by = @{}
  foreach ($w in @($Windows)) {
    $k = $w.id + '|' + $w.store
    if (-not $by.ContainsKey($k)) { $by[$k] = New-Object System.Collections.ArrayList }
    [void]$by[$k].Add($w)
  }
  $rows = New-Object System.Collections.ArrayList
  foreach ($k in @($by.Keys | Sort-Object)) {
    $ws = @($by[$k] | Sort-Object from, to)
    $eps = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($w in $ws) {
      $f = [datetime]::ParseExact($w.from, 'yyyy-MM-dd', $null); $t = [datetime]::ParseExact($w.to, 'yyyy-MM-dd', $null)
      if ($t -lt $f) { $t = $f }
      if ($null -ne $cur -and $f -le $cur.end.AddDays($Slack)) {
        if ($t -gt $cur.end) { $cur.end = $t }
        if ($w.cls -ne 'shelf') { $cur.allShelf = $false }
        if ($w.cls -eq 'ad') { $cur.anyAd = $true }
      } else {
        $cur = [pscustomobject]@{ start = $f; end = $t; allShelf = ($w.cls -eq 'shelf'); anyAd = ($w.cls -eq 'ad') }
        [void]$eps.Add($cur)
      }
    }
    $gaps = @()
    for ($i = 1; $i -lt $eps.Count; $i++) { $gaps += [int]($eps[$i].start - $eps[$i - 1].start).TotalDays }
    $shelfEps = @($eps | Where-Object { $_.allShelf }).Count
    $adEps = @($eps | Where-Object { $_.anyAd }).Count
    $cls = if ($shelfEps -eq $eps.Count) { 'shelf' } elseif ($adEps -eq $eps.Count) { 'ad' } else { 'mixed' }
    $kind = if ($gaps.Count -ge 2) { 'formable' } elseif ($gaps.Count -eq 1) { 'single' } else { 'none' }
    $pred = $null; $err = $null
    if ($gaps.Count -ge 2) {
      $earlier = [double[]]@($gaps[0..($gaps.Count - 2)])
      $pred = Get-CadenceMedian -Values $earlier
      $err = [math]::Abs([double]$gaps[$gaps.Count - 1] - $pred)
    }
    $parts = $k.Split('|')
    [void]$rows.Add([pscustomobject]@{
      id = $parts[0]; store = $parts[1]; windows = $ws.Count; episodes = $eps.Count
      starts = @($eps | ForEach-Object { $_.start.ToString('yyyy-MM-dd') })
      gaps = $gaps; kind = $kind; cls = $cls
      median_gap = (Get-CadenceMedian -Values ([double[]]$gaps)); predicted_last = $pred; abs_err = $err
    })
  }
  return ,$rows
}

function Get-CadenceVerdict {
  <# PURE. Applies I169's bar to the pair rows. #>
  param($Rows, [int]$PromotedCommodities)
  $shelfFormable = @($Rows | Where-Object { $_.cls -eq 'shelf' -and $_.kind -eq 'formable' })
  $covered = @($shelfFormable | ForEach-Object { $_.id } | Sort-Object -Unique).Count
  $covPct = if ($PromotedCommodities -gt 0) { 100.0 * $covered / $PromotedCommodities } else { 0.0 }
  $errs = [double[]]@($shelfFormable | ForEach-Object { [double]$_.abs_err })
  $medErr = Get-CadenceMedian -Values $errs
  $within = @($shelfFormable | Where-Object { $_.abs_err -le $script:BarWithinDays }).Count
  $b1 = ($shelfFormable.Count -ge $script:BarMinFormablePairs) -and ($covPct -ge $script:BarMinCoveragePct)
  $b2 = ($shelfFormable.Count -gt 0) -and ($null -ne $medErr) -and ($medErr -le $script:BarMaxMedianErrDays) -and ((2 * $within) -ge $shelfFormable.Count)
  return [pscustomobject]@{
    ShelfFormable = $shelfFormable.Count; CoveredCommodities = $covered; CoveragePct = $covPct
    MedianAbsErr = $medErr; Within = $within; B1 = $b1; B2 = $b2; Warranted = ($b1 -and $b2)
  }
}

if ($SelfTest) {
  $script:n = 0; $script:fails = 0
  function Assert-Case([string]$Name, [bool]$Ok, [string]$Got) {
    $script:n++
    if ($Ok) { Write-Output ('ok    ' + $Name) } else { $script:fails++; Write-Output ('FAIL  ' + $Name + '  got=' + $Got) }
  }
  function New-Cell([string]$Store, [string]$Type, [string]$From, [string]$To, [string]$Src) {
    return [ordered]@{ store = $Store; type = $Type; ad_from = $From; ad_to = $To; source_ad = $Src; per_unit = 1.0 }
  }
  $tmp = Join-Path $env:TEMP ('psc-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  try {
    New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
    $shop = 'shop.fareway.com (search)'
    $ad = 'Fareway Weekly Ad'
    # Board 1 and board 2 both CARRY the eggs window 2026-01-01..07 - one window, not two.
    # eggs @ Fareway, shelf-found: episodes start 01-01 (with a touching 01-08..14 window), 01-22, 02-05 -> gaps 21, 14
    # milk @ Fareway, ad-borne: 01-01, 01-15 -> one gap of 14 (single)
    # milk @ Hy-Vee, shelf-found: 01-10 only; must NOT join Fareway's milk into a cross-store gap
    # bread: an undated sale at Walmart only
    $b1 = [ordered]@{ comparison = @(
      [ordered]@{ id = 'eggs'; stores = @((New-Cell 'Fareway' 'sale' '2026-01-01' '2026-01-07' $shop)) }
      [ordered]@{ id = 'milk'; stores = @((New-Cell 'Fareway' 'sale' '2026-01-01' '2026-01-07' $ad), (New-Cell 'Hy-Vee' 'sale' '2026-01-10' '2026-01-12' 'Aisles Online current shelf price')) }
      [ordered]@{ id = 'bread'; stores = @((New-Cell 'Walmart' 'sale' '' '' 'everyday shelf price'), (New-Cell 'Aldi' 'everyday' '' '' '')) }
    ) }
    $b2 = [ordered]@{ comparison = @(
      [ordered]@{ id = 'eggs'; stores = @((New-Cell 'Fareway' 'sale' '2026-01-01' '2026-01-07' $shop), (New-Cell 'Fareway' 'sale' '2026-01-08' '2026-01-14' $shop)) }
      [ordered]@{ id = 'milk'; stores = @((New-Cell 'Fareway' 'sale' '2026-01-15' '2026-01-21' $ad)) }
    ) }
    $b3 = [ordered]@{ comparison = @(
      [ordered]@{ id = 'eggs'; stores = @((New-Cell 'Fareway' 'sale' '2026-01-22' '2026-01-28' $shop), (New-Cell 'Fareway' 'sale' '2026-02-05' '2026-02-11' $shop)) }
    ) }
    [IO.File]::WriteAllText((Join-Path $tmp 'comparison-2026-01-02.json'), ($b1 | ConvertTo-Json -Depth 8))
    [IO.File]::WriteAllText((Join-Path $tmp 'comparison-2026-01-09.json'), ($b2 | ConvertTo-Json -Depth 8))
    [IO.File]::WriteAllText((Join-Path $tmp 'comparison-2026-02-06.json'), ($b3 | ConvertTo-Json -Depth 8))
    [IO.File]::WriteAllText((Join-Path $tmp 'comparison-notes.json'), '{"comparison":[]}')   # not a dated board: never read

    $read = Read-CadenceBoards -Dir $tmp
    $rows = Get-CadencePairs -Windows $read.Windows
    $by = @{}; foreach ($r in $rows) { $by[$r.id + '|' + $r.store] = $r }
    $eggs = $by['eggs|Fareway']; $milkF = $by['milk|Fareway']; $milkH = $by['milk|Hy-Vee']

    Assert-Case 'CLEAN TWIN  three dated boards are read and the undated file name is not (3 of 3)' ($read.Boards.Count -eq 3) ([string]$read.Boards.Count)
    Assert-Case 'MUST FIRE  a window carried on two boards is ONE window, not two (eggs has 4 distinct windows)' ($eggs.windows -eq 4) ([string]$eggs.windows)
    Assert-Case 'MUST FIRE  two windows that TOUCH merge into one episode, so consecutive weekly ads are not a 7-day re-promotion' ($eggs.episodes -eq 3 -and ($eggs.gaps -join ',') -eq '21,14') ("episodes=" + $eggs.episodes + " gaps=" + ($eggs.gaps -join ','))
    Assert-Case 'CLEAN TWIN  a pair with two gaps is formable and its last gap is predicted from the earlier (21 vs 14, err 7)' ($eggs.kind -eq 'formable' -and $eggs.predicted_last -eq 21 -and $eggs.abs_err -eq 7) ("kind=" + $eggs.kind + " pred=" + $eggs.predicted_last + " err=" + $eggs.abs_err)
    Assert-Case 'CLEAN TWIN  a shop-found pair classifies shelf, an ad-found pair classifies ad' ($eggs.cls -eq 'shelf' -and $milkF.cls -eq 'ad') ("eggs=" + $eggs.cls + " milk=" + $milkF.cls)
    Assert-Case 'MUST FIRE  one gap is SINGLE, never formable (milk at Fareway)' ($milkF.kind -eq 'single' -and ($milkF.gaps -join ',') -eq '14') ("kind=" + $milkF.kind + " gaps=" + ($milkF.gaps -join ','))
    Assert-Case 'MUST FIRE  the store is part of the key: Hy-Vee milk is its own pair with no gap' ($milkH.episodes -eq 1 -and $milkH.kind -eq 'none') ("episodes=" + $milkH.episodes + " kind=" + $milkH.kind)
    Assert-Case 'MUST FIRE  a sale with no window is counted UNDATED and forms no pair' (($read.UndatedPairs -contains 'bread|Walmart') -and -not $by.ContainsKey('bread|Walmart')) ("undated=" + ($read.UndatedPairs -join ','))
    Assert-Case 'CLEAN TWIN  every commodity id is counted, promoted or not (3)' ($read.CommodityCount -eq 3) ([string]$read.CommodityCount)
    Assert-Case 'CLEAN TWIN  source classes: empty is unknown, a weekly ad is ad, Kroger API is shelf' ((Get-CadenceSourceClass '') -eq 'unknown' -and (Get-CadenceSourceClass 'Hy-Vee Weekly Ad') -eq 'ad' -and (Get-CadenceSourceClass 'kroger-api promo') -eq 'shelf') 'class mismatch'
    $v = Get-CadenceVerdict -Rows $rows -PromotedCommodities 2
    Assert-Case 'MUST FIRE  one formable pair cannot meet the 20-pair coverage bar, so the verdict is NOT warranted' (-not $v.B1 -and -not $v.Warranted -and $v.ShelfFormable -eq 1) ("formable=" + $v.ShelfFormable + " B1=" + $v.B1)
    $r0 = Read-CadenceBoards -Dir (Join-Path $tmp 'absent')
    Assert-Case 'MUST FIRE  an absent board directory resolves ZERO boards and reads BLIND' ($r0.Boards.Count -eq 0 -and [bool](Get-CadenceBlindReason -Read $r0)) ([string]$r0.Boards.Count)
    # A clean checkout carries one tracked board with no dated window at all (comparison-2026-08-08.json).
    $und = Join-Path $tmp 'undated'
    New-Item -ItemType Directory -Path $und -ErrorAction Stop | Out-Null
    $bu = [ordered]@{ comparison = @([ordered]@{ id = 'bread'; stores = @((New-Cell 'Walmart' 'sale' '' '' 'everyday shelf price')) }) }
    [IO.File]::WriteAllText((Join-Path $und 'comparison-2026-01-02.json'), ($bu | ConvertTo-Json -Depth 8))
    $ru = Read-CadenceBoards -Dir $und
    Assert-Case 'MUST FIRE  a board that resolves but holds no DATED window reads BLIND, not a clean zero' ($ru.Boards.Count -eq 1 -and [bool](Get-CadenceBlindReason -Read $ru)) ("boards=" + $ru.Boards.Count + " reason=" + (Get-CadenceBlindReason -Read $ru))
    Assert-Case 'MUST NOT FIRE  the dated fixture boards are not blind' (-not (Get-CadenceBlindReason -Read $read)) (Get-CadenceBlindReason -Read $read)
    # Fareway's weekly ad runs Monday to Saturday: a Saturday end and a Monday start are one continuous promotion.
    $sat = @([pscustomobject]@{ id = 'x'; store = 'Fareway'; from = '2026-01-05'; to = '2026-01-10'; cls = 'ad'; src = '' }, [pscustomobject]@{ id = 'x'; store = 'Fareway'; from = '2026-01-12'; to = '2026-01-17'; cls = 'ad'; src = '' })
    $s1 = Get-CadencePairs -Windows $sat -Slack 1
    $s2 = Get-CadencePairs -Windows $sat -Slack 2
    Assert-Case 'CLEAN TWIN  slack 1 keeps a Saturday end and a Monday start as two episodes; slack 2 merges them' ($s1[0].episodes -eq 2 -and $s2[0].episodes -eq 1) ("slack1=" + $s1[0].episodes + " slack2=" + $s2[0].episodes)
  } catch {
    $script:n++; $script:fails++; Write-Output ('FAIL  the self-test threw: ' + $_.Exception.Message)
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  }
  if ($script:fails -eq 0 -and $script:n -eq 15) { Write-Output ('probe-sale-cadence SELF-TEST PASS: {0} case(s)' -f $script:n); exit 0 }
  Write-Output ('probe-sale-cadence SELF-TEST FAIL: {0} failed, {1} of 15 case(s) ran' -f $script:fails, $script:n)
  exit 1
}

$read = Read-CadenceBoards -Dir $BoardDir
$blind = Get-CadenceBlindReason -Read $read
if ($blind) {
  Write-Output ('probe-sale-cadence: ' + $blind + ' under ' + $BoardDir + ' - the boards are gitignored, so this checkout is BLIND (seed it with ops\seed-worktree.ps1). Not a zero.')
  Write-Output ('PROBE-SALE-CADENCE-COMPLETE boards={0} windows={1} blind=1' -f $read.Boards.Count, $read.Windows.Count)
  exit 3
}
$rows = Get-CadencePairs -Windows $read.Windows -Slack $MergeSlackDays
Write-Output ('episode merge slack: {0} day(s) between one window''s end and the next one''s start (the I169 bar says 1)' -f $MergeSlackDays)
if ($CasesOut) {
  $lines = @($rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 })
  [IO.File]::WriteAllText($CasesOut, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
}
$boardsSorted = @($read.Boards | Sort-Object)
$promoted = @($rows | ForEach-Object { $_.id } | Sort-Object -Unique).Count
$starts = @($rows | ForEach-Object { $_.starts } | Sort-Object)
Write-Output ('boards read: {0} ({1} to {2}); input fingerprint {3}' -f $boardsSorted.Count, $boardsSorted[0], $boardsSorted[-1], $read.Fingerprint)
Write-Output ('history span of episode starts: {0} to {1}' -f $starts[0], $starts[-1])
Write-Output ('commodities on any board: {0}; with a dated sale window: {1}; sale pairs with NO window (undated, not scored): {2}' -f $read.CommodityCount, $promoted, $read.UndatedPairs.Count)
Write-Output ('dated windows (distinct): {0}; (commodity, store) pairs with a window: {1}' -f $read.Windows.Count, $rows.Count)
Write-Output ''
Write-Output 'pairs by gap class and source class:'
foreach ($c in @('shelf', 'ad', 'mixed')) {
  $cr = @($rows | Where-Object { $_.cls -eq $c })
  Write-Output ('  {0,-6} pairs {1,4}: none {2,4}  single {3,4}  formable {4,4}' -f $c, $cr.Count, @($cr | Where-Object { $_.kind -eq 'none' }).Count, @($cr | Where-Object { $_.kind -eq 'single' }).Count, @($cr | Where-Object { $_.kind -eq 'formable' }).Count)
}
Write-Output ''
Write-Output 'pairs by store (formable of total):'
foreach ($g in ($rows | Group-Object store | Sort-Object Name)) {
  $gf = @($g.Group | Where-Object { $_.kind -eq 'formable' })
  $gm = Get-CadenceMedian -Values ([double[]]@($g.Group | ForEach-Object { $_.gaps } | Where-Object { $null -ne $_ }))
  Write-Output ('  {0,-12} {1,4} of {2,4}   all gaps median {3}' -f $g.Name, $gf.Count, $g.Count, $(if ($null -ne $gm) { $gm } else { 'n/a' }))
}
$allGaps = [double[]]@($rows | ForEach-Object { $_.gaps } | Where-Object { $null -ne $_ })
Write-Output ''
Write-Output ('all gaps: {0}, median {1} days, over {2} pair(s) with at least one gap' -f $allGaps.Count, (Get-CadenceMedian -Values $allGaps), @($rows | Where-Object { $_.kind -ne 'none' }).Count)
# I123's comparable figure pooled gaps per COMMODITY across stores. Its test was never written; this is one reading.
$perCom = @($rows | Where-Object { $_.gaps.Count -gt 0 } | Group-Object id | ForEach-Object { Get-CadenceMedian -Values ([double[]]@($_.Group | ForEach-Object { $_.gaps })) })
if ($perCom.Count) { $pc = @($perCom | Sort-Object); Write-Output ('per-commodity median gap (store gaps pooled): {0} commodities, spanning {1} to {2} days' -f $pc.Count, $pc[0], $pc[-1]) }
$v = Get-CadenceVerdict -Rows $rows -PromotedCommodities $promoted
Write-Output ''
Write-Output ('B1 coverage: shelf-found formable pairs {0} (bar {1}); commodities covered {2} of {3} with a dated window ({4:N1}%, bar {5}%) -> {6}' -f $v.ShelfFormable, $script:BarMinFormablePairs, $v.CoveredCommodities, $promoted, $v.CoveragePct, $script:BarMinCoveragePct, $(if ($v.B1) { 'PASS' } else { 'FAIL' }))
Write-Output ('B2 predictability: median |last gap - median of earlier| {0} days (bar {1}); within {2} days: {3} of {4} -> {5}' -f $(if ($null -ne $v.MedianAbsErr) { $v.MedianAbsErr } else { 'n/a' }), $script:BarMaxMedianErrDays, $script:BarWithinDays, $v.Within, $v.ShelfFormable, $(if ($v.B2) { 'PASS' } else { 'FAIL' }))
$allF = @($rows | Where-Object { $_.kind -eq 'formable' })
$allFErr = Get-CadenceMedian -Values ([double[]]@($allF | ForEach-Object { [double]$_.abs_err }))
Write-Output ('  (for reference, every formable pair of any class: {0}, median error {1} days, within {2} days: {3})' -f $allF.Count, $(if ($null -ne $allFErr) { $allFErr } else { 'n/a' }), $script:BarWithinDays, @($allF | Where-Object { $_.abs_err -le $script:BarWithinDays }).Count)
Write-Output ('VERDICT: a cadence-driven worklist change is {0}' -f $(if ($v.Warranted) { 'WARRANTED by the I169 bar' } else { 'NOT warranted by the I169 bar' }))
Write-Output ('PROBE-SALE-CADENCE-COMPLETE boards={0} pairs={1} shelf_formable={2} warranted={3}' -f $boardsSorted.Count, $rows.Count, $v.ShelfFormable, $(if ($v.Warranted) { 1 } else { 0 }))
exit 0
