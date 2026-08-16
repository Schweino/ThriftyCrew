# audit-vocab-integrity.ps1
# ---------------------------------------------------------------------------------------------------
# The referential-integrity edge that had NO guard: every canon name in a spec must resolve to a row in
# db\ingredients.json (by item name or by an adjudicated alias).
#
# The other edge - every bid resolves to something the board/feed actually prices - has had guards for
# a long time (CHEAPEST-FALLBACK in build-v2-spec, audit-store-integrity, feed-covers-published). This
# one had nothing, so on 2026-08-16 recipes wrote "Cream Cheese" while the vocabulary stocked "1/3 Fat
# Cream Cheese", the exact-match lookup missed, and cost-recipes silently priced the line at $0.00.
# Four such pages went live understating cost; ten recipes died in a wave; a day of remediation was
# aimed at "missing prices" that were never missing.
#
# This SUPERSEDES audit-unbid-ingredients.ps1 as the broader check - unbid is the narrow case where the
# name DOES resolve but its row carries no bid. Both run; this one names the right fix.
#
#   .\audit-vocab-integrity.ps1                  sweep every spec in db\recipes
#   .\audit-vocab-integrity.ps1 -Slugs a,b,c     scoped (wave-publish preflight)
#   .\audit-vocab-integrity.ps1 -Json
#   .\audit-vocab-integrity.ps1 -SelfTest
# Exit 0 clean, 1 findings, 2 self-test failure.
# ---------------------------------------------------------------------------------------------------
param(
  [string[]]$Slugs = @(), [string]$RecipesDir, [string]$VocabFile, [string]$NotTrackedOkFile,
  [switch]$Json, [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runJson=[bool]$Json; $runSelfTest=[bool]$SelfTest

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
if (-not $RecipesDir)      { $RecipesDir      = Join-Path $mp 'db\recipes' }
if (-not $VocabFile)       { $VocabFile       = Join-Path $mp 'db\ingredients.json' }
if (-not $NotTrackedOkFile){ $NotTrackedOkFile= Join-Path $mp 'db\not-price-tracked-ok.json' }

$script:MIN_VOCAB = 200

function Read-VocabMaps {
  param([string]$Path)
  # ASSIGN THEN WRAP: `@(Get-Content -Raw | ConvertFrom-Json)` collapses a 282-row array to ONE element,
  # which is the misread that convinced a session this estate owned no ingredients. See ingredient-vocab.ps1.
  $parsed = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json
  $rows = @($parsed)
  $items = @{}; $aliases = @{}; $collisions = @()
  foreach ($r in $rows) {
    $n = [string]$r.item
    if (-not $n -or $n.StartsWith('_')) { continue }
    $items[$n] = $r
  }
  foreach ($r in $rows) {
    $n = [string]$r.item
    if (-not $n -or $n.StartsWith('_')) { continue }
    if ($r.PSObject.Properties.Name -notcontains 'aliases') { continue }
    foreach ($a in @($r.aliases)) {
      $an = [string]$a
      if (-not $an) { continue }
      if ($aliases.ContainsKey($an) -and [string]$aliases[$an].item -ne $n) { $collisions += ("alias '$an' claimed by both '$($aliases[$an].item)' and '$n'") ; continue }
      if ($items.ContainsKey($an)) { $collisions += ("alias '$an' on '$n' is also a real item name") ; continue }
      $aliases[$an] = $r
    }
  }
  return @{ items = $items; aliases = $aliases; collisions = @($collisions); count = @($items.Keys).Count }
}

function Resolve-Name { param([string]$Name, $Maps)
  if ($Maps.items.ContainsKey($Name)) { return $Maps.items[$Name] }
  if ($Maps.aliases.ContainsKey($Name)) { return $Maps.aliases[$Name] }
  return $null }

if ($runSelfTest) {
  $bad = 0
  function T([string]$n,[bool]$ok,[string]$got){ if($ok){Write-Output ("  ok    "+$n)}else{Write-Output ("  X     "+$n+"   got: "+$got); $script:bad++} }

  $tmp = Join-Path $env:TEMP ('vi-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    $v = @(
      [pscustomobject]@{ item='1/3 Fat Cream Cheese'; bid='1-3-fat-cream-cheese'; aliases=@('Cream Cheese') },
      [pscustomobject]@{ item='Miso Paste' }
    )
    ($v | ConvertTo-Json -Depth 6) | Set-Content $tmp -Encoding utf8
    $m = Read-VocabMaps $tmp
    T 'an exact item name resolves' ((Resolve-Name '1/3 Fat Cream Cheese' $m) -ne $null) 'no'
    T 'MUST FIRE  an adjudicated alias resolves (the founding case)' ((Resolve-Name 'Cream Cheese' $m).item -eq '1/3 Fat Cream Cheese') 'alias ignored'
    T 'MUST FIRE  an UNRULED name does not resolve' ($null -eq (Resolve-Name 'Portobello Mushrooms' $m)) 'resolved without a ruling'
    T 'a bid-less row still RESOLVES (that is the unbid case, not the unknown-name case)' ((Resolve-Name 'Miso Paste' $m) -ne $null) 'no'
    T 'no collisions in a clean vocabulary' (@($m.collisions).Count -eq 0) ($m.collisions -join ';')

    # collision must-fires
    $v2 = @([pscustomobject]@{ item='A'; aliases=@('X') }, [pscustomobject]@{ item='B'; aliases=@('X') })
    ($v2 | ConvertTo-Json -Depth 6) | Set-Content $tmp -Encoding utf8
    T 'MUST FIRE  an alias claimed by two rows is a collision' (@((Read-VocabMaps $tmp).collisions).Count -eq 1) 'missed'
    $v3 = @([pscustomobject]@{ item='A'; aliases=@('B') }, [pscustomobject]@{ item='B' })
    ($v3 | ConvertTo-Json -Depth 6) | Set-Content $tmp -Encoding utf8
    T 'MUST FIRE  an alias shadowing a real item name is a collision' (@((Read-VocabMaps $tmp).collisions).Count -eq 1) 'missed'
  } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force } }

  $live = Read-VocabMaps $VocabFile
  T 'MUST FIRE  the live vocabulary parses at full size (the 8-row misread)' ($live.count -ge $script:MIN_VOCAB) ([string]$live.count)
  T 'MUST FIRE  the live vocabulary has NO alias collisions' (@($live.collisions).Count -eq 0) (@($live.collisions) -join '; ')
  T 'MUST FIRE  the ruled "Cream Cheese" alias is present and resolving' ((Resolve-Name 'Cream Cheese' $live) -ne $null) 'ruling lost'

  if ($bad -gt 0) { Write-Output ("audit-vocab-integrity SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'audit-vocab-integrity SELF-TEST PASS'
  Write-GuardComplete -Name 'audit-vocab-integrity' -Summary 'selftest pass'; exit 0
}

$maps = Read-VocabMaps $VocabFile
if ($maps.count -lt $script:MIN_VOCAB) {
  Write-Output ("audit-vocab-integrity: PARSED ONLY {0} vocabulary rows - implausible, refusing to report. Fix the parse, do not act on this." -f $maps.count)
  exit 1
}
if (@($maps.collisions).Count -gt 0) {
  Write-Output 'audit-vocab-integrity: ALIAS COLLISIONS in db\ingredients.json:'
  foreach ($c in $maps.collisions) { Write-Output ("    " + $c) }
  exit 1
}

$allow = @{}
if (Test-Path $NotTrackedOkFile) { foreach ($i in ((Get-Content $NotTrackedOkFile -Raw -Encoding utf8 | ConvertFrom-Json).items)) { $allow[[string]$i] = 1 } }

$slugList = @($Slugs | Where-Object { $_ } | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$files = if (@($slugList).Count) {
  $acc=@(); $missing=@()
  foreach ($s in $slugList) { $p = Join-Path $RecipesDir ($s + '.json'); if (Test-Path $p) { $acc += $p } else { $missing += $s } }
  if (@($missing).Count) { Write-Output ("audit-vocab-integrity: named slug(s) with no spec: {0}" -f ($missing -join ', ')); exit 1 }
  @($acc)
} else { @(Get-ChildItem $RecipesDir -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }

$findings = @()
foreach ($f in $files) {
  $slug = [IO.Path]::GetFileNameWithoutExtension($f)
  try { $j = Get-Content $f -Raw -Encoding utf8 | ConvertFrom-Json } catch { continue }
  $ing = @()
  if ($j.PSObject.Properties.Name -contains 'scaler' -and $j.scaler -and ($j.scaler.PSObject.Properties.Name -contains 'ing')) { $ing = @($j.scaler.ing) }
  if (-not @($ing).Count) { continue }
  $unknown = @(); $unbid = @()
  foreach ($e in $ing) {
    $canon = if ($e.PSObject.Properties.Name -contains 'canon' -and $e.canon) { [string]$e.canon } else { [string]$e.item }
    if ($allow.ContainsKey($canon)) { continue }
    $row = Resolve-Name $canon $maps
    if (-not $row) { $unknown += $canon; continue }
    if (-not ($row.PSObject.Properties.Name -contains 'bid') -or -not $row.bid) { $unbid += $canon }
  }
  if (@($unknown).Count -or @($unbid).Count) {
    $findings += [pscustomobject]@{ slug=$slug; unknown_names=@($unknown | Select-Object -Unique); unbid=@($unbid | Select-Object -Unique) }
  }
}

if ($runJson) { ([pscustomobject]@{ swept=@($files).Count; vocabulary=$maps.count; findings=@($findings) } | ConvertTo-Json -Depth 6); if(@($findings).Count){exit 1}; exit 0 }

Write-Output ("audit-vocab-integrity: swept {0} spec(s) against {1} vocabulary rows" -f @($files).Count, $maps.count)
if (-not @($findings).Count) {
  Write-Output '  ok - every canon name resolves to a row, and every resolved row carries a bid'
  Write-GuardComplete -Name 'audit-vocab-integrity' -Summary ("clean n={0}" -f @($files).Count); exit 0
}
foreach ($f in $findings) {
  if (@($f.unknown_names).Count) { Write-Output ("  UNKNOWN NAME  {0,-46} {1}" -f $f.slug, (@($f.unknown_names) -join ', ')) }
  if (@($f.unbid).Count)         { Write-Output ("  NO BID        {0,-46} {1}" -f $f.slug, (@($f.unbid) -join ', ')) }
}
Write-Output '  UNKNOWN NAME = the name is wrong, the price is probably fine. Rename, alias (adjudicated), or register a row.'
Write-Output '  NO BID       = the name is right, the row genuinely lacks a bid. Wire it, or allowlist in not-price-tracked-ok.json.'
Write-GuardComplete -Name 'audit-vocab-integrity' -Summary ("findings={0}" -f @($findings).Count)
exit 1
