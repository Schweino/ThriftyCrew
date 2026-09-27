<#
  collect-flyer-link-evidence.ps1 - the Family Fare half of the flyer-line labelled set (D5 of
  design/PLAN-link-rides-with-price-2026-09-27.md; the method is design/PLAN-flyer-line-product-link-2026-09-26.md,
  whose Hy-Vee set is grocery/hyvee/flyer-link-evidence-2026-09-26.jsonl and flyer-link-gold.jsonl).

  For each Family Fare flyer tile on a board (link_source=ad), search Freshop (store 6401) and write EVERY candidate the
  search returns, one row each: today's sale price, the regular price, the weight flag and the flyer (circular) ids the
  store ties the product to. Labels are made by judgement over these rows BEFORE any linker runs on them, and Brad
  reviews them. This script only collects; it decides nothing.

  Freshop allows about 40 calls a day before it 400s, so a run searches at most -Max lines and skips lines already in
  the evidence file: two days cover a week's flyer. A line whose search failed is written as kind=search-failed and
  retried next run.
  SCOPE OF A CLEAN REPORT: not a detector.
#>
param([string]$Board = '', [string]$Evidence = '', [int]$Max = 30, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if ($SelfTest) {
  # The one pure step: which lines still need a search, given what the file already holds.
  $held = @{ 'a' = 'candidate'; 'b' = 'search-failed' }
  $need = @(@('a', 'b', 'c') | Where-Object { -not $held.ContainsKey($_) -or $held[$_] -eq 'search-failed' })
  if (($need -join ',') -eq 'b,c') { Write-Output '  ok    MUST FIRE a failed search and an unseen line are searched; a collected line is not'; Write-Output 'collect-flyer-link-evidence self-test pass (1 case)'; exit 0 }
  Write-Output ('  FAIL  lines to search: ' + ($need -join ',')); Write-Output 'collect-flyer-link-evidence self-test FAIL'; exit 1
}
if (-not $Board) { Write-Output 'collect-flyer-link-evidence: -Board is required (a comparison board with link_source)'; Write-Output 'COLLECT-FLYER-LINK-EVIDENCE-COMPLETE blind=no-board'; exit 3 }
if (-not $Evidence) { $Evidence = Join-Path $PSScriptRoot ('flyer-link-evidence-' + (Get-Date).ToString('yyyy-MM-dd') + '.jsonl') }
$day = (Get-Date).ToString('yyyy-MM-dd')
$doc = [IO.File]::ReadAllText($Board) | ConvertFrom-Json
$lines = [ordered]@{}
foreach ($c in @($doc.comparison)) {
  foreach ($s in @($c.stores)) {
    if ([string]$s.store -ne 'Family Fare' -or [string]$s.link_source -ne 'ad' -or $null -eq $s.per_unit) { continue }
    $k = [string]$s.item + ' | ' + [string]$s.ad
    if (-not $lines.Contains($k)) { $lines[$k] = @{ commodity = [string]$c.id; item = [string]$s.item; ad = [string]$s.ad; basis = [string]$s.basis; size = [string]$s.size; per_unit = $s.per_unit } }
  }
}
$held = @{}
if (Test-Path -LiteralPath $Evidence) {
  foreach ($l in [IO.File]::ReadAllLines($Evidence)) { if ($l.Trim()) { $r = $l | ConvertFrom-Json; $key = [string]$r.line + ' | ' + [string]$r.ad; if ($held[$key] -ne 'candidate') { $held[$key] = [string]$r.kind } } }
}
$hdr = @{ 'User-Agent' = 'Mozilla/5.0'; 'Accept' = 'application/json' }
$tok = ''
$searched = 0; $failed = 0; $rowsOut = 0
$out = New-Object System.Collections.Generic.List[string]
foreach ($k in @($lines.Keys)) {
  if ($held.ContainsKey($k) -and $held[$k] -ne 'search-failed') { continue }
  if ($searched -ge $Max) { break }
  $L = $lines[$k]
  $term = ((([string]$L.item) -split ',')[0] -replace '\$[0-9.]+', '' -replace '\s+', ' ').Trim()
  $items = $null
  for ($try = 0; $try -lt 2 -and $null -eq $items; $try++) {
    $tq = if ($tok) { '&token=' + $tok } else { '' }
    try {
      $r = Invoke-RestMethod -Uri ('https://api.freshop.ncrcloud.com/1/products?app_key=family_fare&store_id=6401' + $tq + '&limit=25&q=' + [uri]::EscapeDataString($term)) -Headers $hdr -TimeoutSec 25
      if (@($r.items).Count -gt 0) { $items = @($r.items) }
    } catch { }
    if ($null -eq $items) { try { $tok = [string](Invoke-RestMethod -Uri 'https://api.freshop.ncrcloud.com/1/sessions?app_key=family_fare' -Method Post -Headers $hdr -TimeoutSec 20).token } catch { }; Start-Sleep -Milliseconds 700 }
  }
  $searched++
  $base = [ordered]@{ read_day = $day; store = 'Family Fare'; commodity = $L.commodity; line = $L.item; ad = $L.ad; basis = $L.basis; tile_size = $L.size; tile_per_unit = $L.per_unit; via = ('search: ' + $term) }
  if ($null -eq $items) { $failed++; $row = [ordered]@{ kind = 'search-failed' } + $base; $out.Add(($row | ConvertTo-Json -Compress)); continue }
  foreach ($p in $items) {
    $row = [ordered]@{ kind = 'candidate' } + $base
    $row['product_id'] = [string]$p.id; $row['name'] = [string]$p.name; $row['size_field'] = [string]$p.size
    $row['price'] = [string]$p.price; $row['sale_price'] = [string]$p.sale_price; $row['base_price'] = $p.base_price
    $row['sale_start'] = [string]$p.sale_start_date; $row['sale_finish'] = [string]$p.sale_finish_date
    $row['on_sale'] = [bool]$p.sale_price; $row['circular_ids'] = @($p.circular_ids); $row['is_weighted'] = [bool]$p.is_weight_required
    $row['canonical_url'] = [string]$p.canonical_url
    $out.Add(($row | ConvertTo-Json -Compress -Depth 4)); $rowsOut++
  }
  Start-Sleep -Milliseconds 500
}
if ($out.Count) { [IO.File]::AppendAllText($Evidence, (($out.ToArray()) -join "`n") + "`n", (New-Object Text.UTF8Encoding($false))) }   # atomic-replace:allow a one-writer append-only evidence log
$left = @($lines.Keys | Where-Object { -not $held.ContainsKey($_) -or $held[$_] -eq 'search-failed' }).Count - ($searched - $failed)
Write-Output ('collect-flyer-link-evidence: Family Fare flyer lines ' + $lines.Count + ', searched ' + $searched + ' (cap ' + $Max + '), search failed ' + $failed + ', candidate rows written ' + $rowsOut + ', lines still to search ' + $left)
Write-Output ('COLLECT-FLYER-LINK-EVIDENCE-COMPLETE lines=' + $lines.Count + ' searched=' + $searched + ' failed=' + $failed + ' left=' + $left)
exit 0
