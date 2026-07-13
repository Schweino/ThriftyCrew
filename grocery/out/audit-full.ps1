# Deep data-quality audit of the 301-commodity board. Read-only; prints findings by section.
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\income\grocery'
$tmpC = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'commodities.json'))); $commods = @($tmpC)
$cats = (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'categories.json')))).categories
$terms = (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'commodity-search.json')))).terms
$cmpF = Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$cmp = @((ConvertFrom-Json ([IO.File]::ReadAllText($cmpF.FullName))).comparison)

Write-Output "===== 1. STRUCTURAL INTEGRITY ====="
$ids = @($commods | ForEach-Object { [string]$_.id })
$dupe = @($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
Write-Output ("commodities: " + $ids.Count + "  duplicate ids: " + $(if ($dupe.Count) { $dupe -join ', ' } else { 'none' }))
$catIds = @(); foreach ($c in $cats) { $catIds += @($c.commodities) }
$orphanCat = @($catIds | Where-Object { $ids -notcontains $_ } | Select-Object -Unique)
$noCat = @($ids | Where-Object { $catIds -notcontains $_ })
Write-Output ("category ids missing from commodities: " + $(if ($orphanCat.Count) { $orphanCat -join ', ' } else { 'none' }))
Write-Output ("commodities in NO category: " + $(if ($noCat.Count) { $noCat -join ', ' } else { 'none' }))
$noTerm = @($ids | Where-Object { -not $terms.PSObject.Properties[$_] })
Write-Output ("commodities with NO search term: " + $(if ($noTerm.Count) { $noTerm -join ', ' } else { 'none' }))
$badRx = @()
foreach ($c in $commods) { foreach ($p in (@($c.include) + @($c.exclude) + @($c.relax_global))) { if ($p) { try { [void][regex]::new($p) } catch { $badRx += ($c.id + ': ' + $p) } } } }
Write-Output ("invalid regex patterns: " + $(if ($badRx.Count) { ($badRx -join ' | ') } else { 'none' }))

Write-Output ""
Write-Output "===== 2. PRICE SANITY (per-unit outliers = likely wrong product or unit bug) ====="
$byId2 = @{}; foreach ($c in $commods) { $byId2[[string]$c.id] = $c }
$flag = 0
foreach ($r in $cmp) {
  $ps = @($r.stores | ForEach-Object { [double]$_.per_unit } | Where-Object { $_ -gt 0 } | Sort-Object)
  if ($ps.Count -lt 3) { continue }
  $med = $ps[[int]([math]::Floor($ps.Count/2))]
  $lo = $ps[0]; $hi = $ps[-1]
  # cheapest wildly below the pack (< 35% of median) OR priciest wildly above (> 4x median) -> suspect
  if ($med -gt 0 -and ($lo -lt $med * 0.35 -or $hi -gt $med * 4.5)) {
    $lostore = @($r.stores | Sort-Object per_unit | Select-Object -First 1).store
    $histore = @($r.stores | Sort-Object per_unit -Descending | Select-Object -First 1).store
    Write-Output ("  {0,-24} med {1,7:N3}/{2}  LOW {3,7:N3} ({4})  HIGH {5,7:N3} ({6})" -f $r.id, $med, $r.unit, $lo, $lostore, $hi, $histore)
    $flag++
  }
}
Write-Output ("  -> " + $flag + " commodities with an outlier price (review the low/high store's product)")

Write-Output ""
Write-Output "===== 3. NO-LINK backlog by store (priced chip, no See-item link) ====="
$rep = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'out\consistency-report.json')))
$byStore = @($rep.no_link | Group-Object store | Sort-Object Count -Descending)
foreach ($g in $byStore) { Write-Output ("  {0,-13} {1}" -f $g.Name, $g.Count) }
Write-Output ("  total no-link: " + $rep.no_link_count + "   mismatch backlog: " + $rep.mismatch_count)

Write-Output ""
Write-Output "===== 4. EMPTY / DEGENERATE ROWS ====="
$oneStore = @($cmp | Where-Object { @($_.stores).Count -eq 1 })
Write-Output ("commodities priced at only ONE store: " + $oneStore.Count + $(if ($oneStore.Count) { ' (' + (@($oneStore | ForEach-Object { $_.id }) -join ', ') + ')' } else { '' }))
$zeroPU = @()
foreach ($r in $cmp) { foreach ($s in $r.stores) { if ([double]$s.per_unit -le 0) { $zeroPU += ($r.id + '/' + $s.store) } } }
Write-Output ("chips with per_unit <= 0: " + $(if ($zeroPU.Count) { $zeroPU -join ', ' } else { 'none' }))
