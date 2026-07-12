<#
  update-history.ps1 - Maintains a persistent per-commodity CHEAPEST-PRICE HISTORY so we can later say
  "cheapest since <date>" / "lowest in N weeks" when a big sale lands.

  Run ONCE per week after finalizing the comparison (generate it at -MinStores 1 so single-store lows are
  tracked too - a price point is a price point). It:
    1) upserts this week's cheapest (overall + per-store) into price-history.json (keyed by commodity, by week),
    2) recomputes each commodity's all-time record low,
    3) prints + saves this week's BADGES (record low / ties / cheapest-since-<date> / lowest-in-N-weeks).
  Idempotent: re-running for the same week replaces that week's row (no double-count).

  (Written with plain arrays + Where-Object + [ordered] hashtables only - this Windows PowerShell 5.1
   host throws on several generic-List / id-keyed-hashtable constructs.)
#>
param(
  [string]$CompareFile = "",
  [string]$HistoryFile = "",
  [string]$OutDir = ""
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir)      { $OutDir = Join-Path $root 'out' }
if (-not $HistoryFile) { $HistoryFile = Join-Path $root 'price-history.json' }
if (-not $CompareFile) { $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }

$cmpDoc = Get-Content $CompareFile -Raw | ConvertFrom-Json
$week   = [string]$cmpDoc.week_of
$rows   = @($cmpDoc.comparison)

$existing = @()
if (Test-Path $HistoryFile) { $existing = @((Get-Content $HistoryFile -Raw | ConvertFrom-Json).commodities) }

function Weeks-Between($a, $b) { try { return [math]::Round([math]::Abs((([datetime]$a) - ([datetime]$b)).Days) / 7.0) } catch { return $null } }

$updated    = @()   # rebuilt commodity records (ordered hashtables)
$updatedIds = @{}
$badges     = @()

foreach ($row in $rows) {
  $id  = [string]$row.id
  $P   = [double]$row.cheapest_price
  $ec  = $existing | Where-Object { $_.id -eq $id } | Select-Object -First 1
  $prior = @()
  if ($ec) { $prior = @($ec.history | Where-Object { $_.week_of -ne $week }) }

  # ---- badge from prior weeks ----
  $status='baseline'; $detail='first week tracked'; $since=$null; $weeks=$null
  if (@($prior).Count -gt 0) {
    $priorMin = $null
    foreach ($h in $prior) { $hp=[double]$h.cheapest_price; if ($priorMin -eq $null -or $hp -lt $priorMin) { $priorMin=$hp } }
    if ($P -lt $priorMin) { $status='record_low'; $detail=("new record low, prev best `$" + ('{0:N2}' -f $priorMin)) }
    elseif ($P -eq $priorMin) { $status='ties_record'; $detail='ties the record low' }
    else {
      # count consecutive most-recent weeks strictly ABOVE P; stop at the first week at-or-below P.
      # only a genuine dip (>=2 recent weeks were pricier) earns a "lowest in N weeks" flag.
      $weeksAbove=0; $since=$null
      foreach ($h in ($prior | Sort-Object week_of -Descending)) {
        if ([double]$h.cheapest_price -gt $P) { $weeksAbove++ } else { $since=$h.week_of; break }
      }
      if ($weeksAbove -ge 2) { $weeks=$weeksAbove; $status='low_since'; $detail=("cheapest since $since, lowest in ~$weeksAbove wk") }
      else { $status='tracking'; $detail='not lower than recent weeks' }
    }
  }
  $badges += ,([ordered]@{ id=$id; commodity=$row.commodity; unit=$row.unit; price=$P; store=$row.cheapest_store; weeks_tracked=(@($prior).Count+1); status=$status; detail=$detail; since=$since; weeks_since=$weeks })

  # ---- this week's record + upsert ----
  $ps = [ordered]@{}; foreach ($s in $row.stores) { $ps[[string]$s.store] = $s.per_unit }
  $thisWeek = [ordered]@{ week_of=$week; cheapest_price=$P; cheapest_store=$row.cheapest_store; per_store=$ps }
  $newHistory = @()
  foreach ($h in $prior) { $newHistory += ,$h }
  $newHistory += ,$thisWeek

  # ---- all-time record low over the full history ----
  $rl = $null
  foreach ($h in $newHistory) { $hp=[double]$h.cheapest_price; if ($rl -eq $null -or $hp -lt $rl.price) { $rl=[ordered]@{ price=$hp; store=$h.cheapest_store; week_of=$h.week_of } } }

  $updated += ,([ordered]@{ id=$id; label=$row.commodity; unit=$row.unit; record_low=$rl; history=$newHistory })
  $updatedIds[$id] = $true
}

# ---- ALSO track the recipe-ingredient board (added 2026-07-11 for the per-item history popup) ----
# Same weekly upsert, marked src='recipe' so trend-page generation and staples trend-links can
# exclude them until we choose to expand. NO badges for these (they'd flood records-<week>.json).
$riFile = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $riFile) {
  foreach ($row in @((Get-Content $riFile -Raw | ConvertFrom-Json).comparison)) {
    $id = [string]$row.id
    if ($updatedIds.ContainsKey($id)) { continue }   # weekly board already recorded this id
    $P = $null; foreach ($s in $row.stores) { $sp = [double]$s.per_unit; if ($sp -gt 0 -and ($null -eq $P -or $sp -lt $P)) { $P = $sp } }
    if ($null -eq $P) { continue }
    $cs = ''; foreach ($s in $row.stores) { if ([double]$s.per_unit -eq $P) { $cs = [string]$s.store; break } }
    $ec = $existing | Where-Object { $_.id -eq $id } | Select-Object -First 1
    $prior = @()
    if ($ec) { $prior = @($ec.history | Where-Object { $_.week_of -ne $week }) }
    $ps = [ordered]@{}; foreach ($s in $row.stores) { if ([double]$s.per_unit -gt 0) { $ps[[string]$s.store] = $s.per_unit } }
    $thisWeek = [ordered]@{ week_of=$week; cheapest_price=$P; cheapest_store=$cs; per_store=$ps }
    $newHistory = @()
    foreach ($h in $prior) { $newHistory += ,$h }
    $newHistory += ,$thisWeek
    $rl = $null
    foreach ($h in $newHistory) { $hp=[double]$h.cheapest_price; if ($rl -eq $null -or $hp -lt $rl.price) { $rl=[ordered]@{ price=$hp; store=$h.cheapest_store; week_of=$h.week_of } } }
    $updated += ,([ordered]@{ id=$id; label=[string]$row.commodity; unit=[string]$row.unit; src='recipe'; record_low=$rl; history=$newHistory })
    $updatedIds[$id] = $true
  }
}

# ---- carry forward commodities that had no ad this week (unchanged) ----
foreach ($ec in $existing) { if (-not $updatedIds.ContainsKey([string]$ec.id)) { $updated += ,$ec } }

# ---- compaction (Brad 2026-07-11): keep DAILY granularity for the last 21 days, then collapse
# older entries to ONE per calendar week. We keep each old week's LOWEST-cheapest entry (not the
# last one) so a mid-week record low is never erased and record_low recomputation stays honest.
$dailyCut = (Get-Date).AddDays(-21).ToString('yyyy-MM-dd')
$compacted = @()
foreach ($u in $updated) {
  $recent = @(); $old = @()
  foreach ($h in $u.history) { if ([string]$h.week_of -ge $dailyCut) { $recent += ,$h } else { $old += ,$h } }
  if (@($old).Count -gt 0) {
    $byWeek = @{}
    foreach ($h in $old) {
      try { $d = [datetime]$h.week_of } catch { continue }
      $ws = $d.AddDays(-((([int]$d.DayOfWeek) + 6) % 7)).ToString('yyyy-MM-dd')   # Monday of that week
      if (-not $byWeek.ContainsKey($ws) -or [double]$h.cheapest_price -lt [double]$byWeek[$ws].cheapest_price) { $byWeek[$ws] = $h }
    }
    $keptOld = @(); foreach ($k in ($byWeek.Keys | Sort-Object)) { $keptOld += ,$byWeek[$k] }
    $newHist = @(); foreach ($h in $keptOld) { $newHist += ,$h }; foreach ($h in $recent) { $newHist += ,$h }
    $u.history = @($newHist | Sort-Object week_of)
  }
  $compacted += ,$u
}
$updated = $compacted

# ---- persist ----
$maxWeeks = 0; foreach ($u in $updated) { $hc = @($u.history).Count; if ($hc -gt $maxWeeks) { $maxWeeks = $hc } }
([ordered]@{ updated=$week; weeks_on_record=$maxWeeks; commodities=$updated } | ConvertTo-Json -Depth 9) | Set-Content $HistoryFile -Encoding UTF8

# ---- this week's highlight badges ----
$notable = @($badges | Where-Object { $_.status -eq 'record_low' -or $_.status -eq 'ties_record' -or $_.status -eq 'low_since' } | Sort-Object @{E={$_.weeks_since};Descending=$true})
([ordered]@{ week_of=$week; notable=$notable; all=$badges } | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $OutDir ("records-"+$week+".json")) -Encoding UTF8

Write-Output ("Price history updated: " + $HistoryFile)
Write-Output ("Week $week  -  commodities tracked this week: " + (@($rows).Count) + "   weeks on record (max): " + $maxWeeks)
Write-Output ""
if (@($notable).Count -gt 0) {
  Write-Output "HEADLINE-WORTHY THIS WEEK:"
  foreach ($b in $notable) {
    $tag = switch ($b.status) { 'record_low' {'RECORD LOW'} 'ties_record' {'TIES RECORD'} 'low_since' {("LOWEST IN ~"+$b.weeks_since+" WK")} default {$b.status} }
    Write-Output ('  {0,-24} ${1,-7}/{2,-5} {3,-11} [{4}] {5}' -f $b.commodity, ('{0:N2}' -f $b.price), $b.unit, $b.store, $tag, $b.detail)
  }
} else {
  Write-Output "No records to flag yet - looks like week 1 of tracking. Badges activate automatically as weeks accumulate."
}
