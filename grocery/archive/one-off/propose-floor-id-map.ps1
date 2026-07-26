<#
  propose-floor-id-map.ps1 - evidence-gated mapping proposals for recipe-floor-id-map.json (2026-07-23).

  The monthly deriver needs recipe-era floor ids mapped to board commodity ids, and a WRONG mapping is
  the board-collision class (a floor silently priced off a different product). So this tool does not
  guess: it PROPOSES a mapping only when three independent signals all agree -
    1. NAME: the recipe row's commodity label and the board commodity's label share their distinctive
       tokens (normalized, plural-insensitive).
    2. UNIT: identical or standard-convertible (lb/oz/floz/kg/g).
    3. PRICE: in at least MinAgreeStores overlapping stores, the recipe row's CURRENT floor price agrees
       with the board candidate's cheapest EVERYDAY candidate within Tol (unit-converted). Same commodity
       in the same form prices the same; fresh-vs-frozen or block-vs-shredded disagrees and self-rejects.
  Everything else lands in the 'unproven' list with its evidence, for a human/browser check.

  Output: out\floor-id-map-proposals.json {proposals:[{recipe_id,board_id,evidence...}], unproven:[...]}.
  A reviewer then copies accepted proposals into recipe-floor-id-map.json (with reviewed dates).
#>
param([double]$Tol = 0.25, [int]$MinAgreeStores = 2)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$outDir = Join-Path $root 'out'

$floor = (Get-Content (Join-Path $outDir 'recipe-board-everyday.json') -Raw | ConvertFrom-Json).comparison
$commodities = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$candDoc = Get-Content ((Get-ChildItem (Join-Path $outDir 'candidates-*.json') | Where-Object { $_.BaseName -match '^candidates-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1).FullName) -Raw | ConvertFrom-Json
$candById = @{}; foreach ($c in $candDoc.commodities) { $candById[$c.id] = $c }
$idMapF = Join-Path $root 'recipe-floor-id-map.json'
$existing = @{}
foreach ($p in ((Get-Content $idMapF -Raw | ConvertFrom-Json).map).PSObject.Properties) { $existing[$p.Name] = $true }

$UNIT_G = @{ lb = 453.592; oz = 28.3495; floz = 29.57; kg = 1000.0; g = 1.0 }
function Norm([string]$s) {
  $t = $s.ToLower() -replace '[^a-z0-9 ]', ' ' -replace '\s+', ' '
  # crude plural-insensitivity per token
  return (($t.Trim() -split ' ') | ForEach-Object { $_ -replace 'ies$', 'y' -replace 'oes$', 'o' -replace 's$', '' }) -join ' '
}
$STOP = @('fresh','whole','plain','large','the','and')

$proposals = New-Object System.Collections.Generic.List[object]
$unproven  = New-Object System.Collections.Generic.List[object]

foreach ($row in $floor) {
  if ($candById.ContainsKey($row.id) -or $existing.ContainsKey($row.id)) { continue }  # already resolvable
  $rTok = @((Norm ([string]$row.commodity)) -split ' ' | Where-Object { $_.Length -gt 1 -and $STOP -notcontains $_ })
  # score every board commodity by token overlap (label AND id)
  $best = $null; $bestScore = 0
  foreach ($bc in $commodities) {
    $bTok = @((Norm (([string]$bc.label) + ' ' + ([string]$bc.id -replace '-', ' '))) -split ' ' | Where-Object { $_.Length -gt 1 })
    $hit = 0; foreach ($t in $rTok) { if ($bTok -contains $t) { $hit++ } }
    if ($rTok.Count -eq 0) { continue }
    $score = $hit / $rTok.Count
    if ($score -gt $bestScore) { $bestScore = $score; $best = $bc }
  }
  if (-not $best -or $bestScore -lt 0.99) {  # ALL distinctive recipe tokens must appear in the board label/id
    $unproven.Add([pscustomobject]@{ recipe_id = $row.id; reason = 'no full-token board label match'; best_guess = if ($best) { $best.id } else { $null }; score = [math]::Round($bestScore,2) })
    continue
  }
  $c = $candById[[string]$best.id]
  if (-not $c) { $unproven.Add([pscustomobject]@{ recipe_id = $row.id; reason = 'board id has no candidates this week'; best_guess = $best.id }); continue }
  # unit reconciliation
  $factor = $null
  if ([string]$row.unit -eq [string]$c.unit) { $factor = 1.0 }
  elseif ($UNIT_G.ContainsKey([string]$row.unit) -and $UNIT_G.ContainsKey([string]$c.unit)) { $factor = $UNIT_G[[string]$row.unit] / $UNIT_G[[string]$c.unit] }
  if ($null -eq $factor) { $unproven.Add([pscustomobject]@{ recipe_id = $row.id; reason = "unit mismatch (row '$($row.unit)' vs board '$($c.unit)')"; best_guess = $best.id }); continue }
  # multi-store price agreement: recipe row's CURRENT floors vs board's cheapest everyday candidate per store
  $agree = 0; $checked = 0; $detail = @()
  foreach ($s in @($row.stores)) {
    $bestCand = @($c.candidates) | Where-Object { $_.store -eq $s.store -and $_.price_type -eq 'everyday' -and $_.unit_price } | Sort-Object { [double]$_.unit_price } | Select-Object -First 1
    if (-not $bestCand) { continue }
    $checked++
    $boardInRowUnit = [double]$bestCand.unit_price * $factor
    $old = [double]$s.per_unit
    if ($old -gt 0 -and ([math]::Abs($boardInRowUnit - $old) / $old) -le $Tol) { $agree++; $detail += ("{0} {1:N2}~{2:N2}" -f $s.store, $old, $boardInRowUnit) }
    else { $detail += ("{0} {1:N2}!={2:N2}" -f $s.store, $old, $boardInRowUnit) }
  }
  if ($agree -ge $MinAgreeStores) {
    $proposals.Add([pscustomobject]@{ recipe_id = $row.id; board_id = [string]$best.id; recipe_label = [string]$row.commodity; board_label = [string]$best.label; unit = ("{0}->{1} x{2}" -f $row.unit, $c.unit, [math]::Round($factor,4)); stores_agreeing = "$agree/$checked"; prices = ($detail -join ' | ') })
  } else {
    $unproven.Add([pscustomobject]@{ recipe_id = $row.id; reason = ("label+unit matched '{0}' but only {1}/{2} store prices agree (form difference?)" -f $best.id, $agree, $checked); best_guess = $best.id; prices = ($detail -join ' | ') })
  }
}

[pscustomobject]@{ generated = (Get-Date).ToString('s'); tol = $Tol; min_agree = $MinAgreeStores; proposals = $proposals; unproven = $unproven } |
  ConvertTo-Json -Depth 5 | Set-Content (Join-Path $outDir 'floor-id-map-proposals.json') -Encoding UTF8
Write-Output ("floor-id-map: {0} evidence-backed proposal(s), {1} unproven (details: out\floor-id-map-proposals.json)" -f $proposals.Count, $unproven.Count)
foreach ($p in $proposals) { Write-Output ("  MAP  {0} -> {1}  [{2}]  {3}" -f $p.recipe_id, $p.board_id, $p.stores_agreeing, $p.prices) }
