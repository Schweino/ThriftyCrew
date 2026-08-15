<#
  audit-commodity-dupes.ps1 - detect the same food priced under two commodity ids.

  FOUNDING CASES (2026-08-15, both found by Brad eyeballing the live page, neither by any guard):
    bread-crumbs vs breadcrumbs      The weekly board priced "Bread Crumbs / Panko" at $0.0743/oz while the
                                     recipe board priced "Panko Breadcrumbs" at $0.218/oz - the SAME FOOD,
                                     2.9x apart, and two recipes paid the dear price for a month.
    zero-sugar-soda vs -soda-2l      Same product class, two ids, two units - and the each-basis row's crown
                                     was a Welch's grape DRINK, not soda. Zero recipes consumed it.
  Both hid because the id namespace spans FILES: the weekly catalog (commodities.json), the recipe overlay
  rule set (recipe-commodities.json), and the recipe-board baseline (out\recipe-board-everyday.json), whose
  row set is its own authority. No single file contained both halves of either duplicate, so no per-file
  check could see them. This audit reads all three namespaces and compares the union.

  WHAT COUNTS AS A SUSPECT (high precision on purpose - this pages a human, so a false positive costs trust):
    a. two ids identical after normalization (lowercase, strip non-alphanumerics): bread-crumbs==breadcrumbs
    b. two ids identical after normalization + trailing-s stemming: tortilla==tortillas
    c. one normalized id is a PREFIX of the other with <=3 chars left over: zerosugarsoda[2l]
       (contains-anywhere is deliberately NOT flagged: 'pineapple' contains 'apple')
    d. two LABELS identical after normalization
  DELIBERATE VARIANTS ARE NOT DUPES. The recipe board carries lower-fat/specific variants by design
  (light-sour-cream vs sour-cream, greek-yogurt vs yogurt) and fresh/canned/cooked forms are different foods
  (sweet-corn vs canned-sweet-corn). Reviewed pairs live in commodity-dupe-allowlist.json keyed on the exact
  id pair with a written reason - the same contested-flag contract every other allowlist here uses. NEVER
  add an entry to silence a finding; the entry must say why the two ids are genuinely different purchases.

  Advisory (exit 2 = suspects found) - it pages, it does not block a publish. A duplicate misprices by
  disagreement, which the basis/consistency guards cannot see because each half is internally consistent.

  Usage:
    .\audit-commodity-dupes.ps1
    .\audit-commodity-dupes.ps1 -SelfTest
#>
param([string]$Root = '', [string]$OutDir = '', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
if (-not $OutDir) { $OutDir = Join-Path $Root 'out' }

function Get-NormId([string]$s) { return (($s.ToLowerInvariant()) -replace '[^a-z0-9]', '') }
function Get-Stem([string]$s) { $n = Get-NormId $s; if ($n.Length -gt 3 -and $n.EndsWith('s')) { return $n.Substring(0, $n.Length - 1) }; return $n }
# ORDINAL pair key, not Sort-Object. PS 5.1's Sort-Object is a culture word-sort that IGNORES HYPHENS, so
# @('bread-crumbs','breadcrumbs') sorts 'breadcrumbs' first on this machine and could sort differently on
# another locale - which would silently re-key the allowlist and un-review every reviewed pair. Ordinal
# comparison is locale-independent.
function Get-PairKey([string]$a, [string]$b) {
  if ([string]::CompareOrdinal($a, $b) -le 0) { return ($a + '|' + $b) }
  return ($b + '|' + $a)
}

# Pure so the self-test can freeze the founding cases without touching a single live file.
function Find-DupeSuspects($Entries, $Allow) {
  # $Entries: array of @{ id; label; source }. $Allow: array of @{ a; b } reviewed pairs.
  $allowKey = @{}
  foreach ($p in @($Allow)) { if ($p.a -and $p.b) { $allowKey[(Get-PairKey ([string]$p.a) ([string]$p.b))] = $true } }
  $suspects = New-Object System.Collections.ArrayList
  $seenPair = @{}
  $list = @($Entries)
  for ($i = 0; $i -lt $list.Count; $i++) {
    for ($j = $i + 1; $j -lt $list.Count; $j++) {
      $A = $list[$i]; $B = $list[$j]
      if ([string]$A.id -eq [string]$B.id) { continue }   # same id in two namespaces is the DESIGN, not a dupe
      $pairK = Get-PairKey ([string]$A.id) ([string]$B.id)
      if ($seenPair.ContainsKey($pairK) -or $allowKey.ContainsKey($pairK)) { continue }
      $na = Get-NormId $A.id; $nb = Get-NormId $B.id
      $reason = $null
      if ($na -eq $nb) { $reason = 'ids identical once separators are stripped' }
      elseif ((Get-Stem $A.id) -eq (Get-Stem $B.id)) { $reason = 'ids identical after singular/plural stemming' }
      elseif ($na.Length -gt $nb.Length -and $na.StartsWith($nb) -and ($na.Length - $nb.Length) -le 3) { $reason = ('one id is the other plus a short suffix ("' + $na.Substring($nb.Length) + '")') }
      elseif ($nb.Length -gt $na.Length -and $nb.StartsWith($na) -and ($nb.Length - $na.Length) -le 3) { $reason = ('one id is the other plus a short suffix ("' + $nb.Substring($na.Length) + '")') }
      elseif ($A.label -and $B.label -and (Get-NormId $A.label) -eq (Get-NormId $B.label)) { $reason = 'labels identical once normalized' }
      if ($reason) {
        $seenPair[$pairK] = $true
        [void]$suspects.Add([pscustomobject]@{ a = [string]$A.id; a_source = [string]$A.source; b = [string]$B.id; b_source = [string]$B.source; reason = $reason })
      }
    }
  }
  return @($suspects)
}

if ($SelfTest) {
  # Hermetic. The founding bugs are frozen as must-fire fixtures beside clean twins.
  $bad = 0
  $fix = @(
    @{ id = 'bread-crumbs'; label = 'Bread Crumbs / Panko'; source = 'weekly' },
    @{ id = 'breadcrumbs'; label = 'Panko Breadcrumbs'; source = 'recipe-board' },
    @{ id = 'zero-sugar-soda'; label = 'Zero-Sugar Soda'; source = 'recipe-board' },
    @{ id = 'zero-sugar-soda-2l'; label = 'Zero-Sugar Soda (2 L)'; source = 'recipe-board' },
    @{ id = 'pineapple-juice'; label = 'Pineapple Juice'; source = 'recipe-board' },
    @{ id = 'apple-juice'; label = 'Apple Juice'; source = 'weekly' },
    @{ id = 'sweet-corn'; label = 'Sweet Corn (ear)'; source = 'weekly' },
    @{ id = 'canned-sweet-corn'; label = 'Canned Sweet Corn'; source = 'recipe-board' },
    @{ id = 'tortillas'; label = 'Tortillas'; source = 'weekly' },
    @{ id = 'tortilla'; label = 'Tortilla'; source = 'recipe-board' }
  )
  $s = Find-DupeSuspects $fix @()
  $pairs = @($s | ForEach-Object { Get-PairKey $_.a $_.b })
  if ($pairs -notcontains 'bread-crumbs|breadcrumbs') { Write-Output '  X MUST-FIRE: bread-crumbs vs breadcrumbs not flagged'; $bad++ }
  if ($pairs -notcontains 'zero-sugar-soda|zero-sugar-soda-2l') { Write-Output '  X MUST-FIRE: zero-sugar-soda vs -2l not flagged'; $bad++ }
  if ($pairs -notcontains 'tortilla|tortillas') { Write-Output '  X singular/plural not flagged'; $bad++ }
  if ($pairs -contains 'apple-juice|pineapple-juice') { Write-Output '  X FALSE-POSITIVE: pineapple-juice flagged against apple-juice (contains-anywhere leak)'; $bad++ }
  if ($pairs -contains 'canned-sweet-corn|sweet-corn') { Write-Output '  X FALSE-POSITIVE: canned vs fresh corn flagged (different foods)'; $bad++ }
  # the allowlist must silence a reviewed pair, keyed on the exact pair
  $s2 = Find-DupeSuspects $fix @(@{ a = 'tortillas'; b = 'tortilla' })
  $p2 = @($s2 | ForEach-Object { Get-PairKey $_.a $_.b })
  if ($p2 -contains 'tortilla|tortillas') { Write-Output '  X a reviewed pair was not silenced'; $bad++ }
  if ($p2 -notcontains 'bread-crumbs|breadcrumbs') { Write-Output '  X the allowlist silenced MORE than its pair'; $bad++ }
  # same id in two namespaces is the design, never a finding
  $s3 = Find-DupeSuspects @(@{ id = 'butter'; label = 'Butter'; source = 'weekly' }, @{ id = 'butter'; label = 'Butter'; source = 'recipe-rules' }) @()
  if (@($s3).Count -ne 0) { Write-Output '  X the same id in two namespaces was flagged as its own duplicate'; $bad++ }
  if ($bad -eq 0) { Write-Output 'audit-commodity-dupes SELF-TEST PASS (both founding dupes fire; pineapple/apple and canned/fresh stay clean; allowlist is pair-exact)'; exit 0 }
  Write-Output ("audit-commodity-dupes SELF-TEST FAIL ({0} problem(s))" -f $bad); exit 1
}

# ---- live run: union the three id namespaces --------------------------------------------------------
function Read-Utf8Json([string]$p) { return ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) -replace '^﻿', '') | ConvertFrom-Json }
$entries = New-Object System.Collections.ArrayList
$wk = Read-Utf8Json (Join-Path $Root 'commodities.json')
foreach ($c in $wk) { [void]$entries.Add(@{ id = [string]$c.id; label = [string]$c.label; source = 'commodities.json' }) }
$rcF = Join-Path $Root 'recipe-commodities.json'
if (Test-Path $rcF) { foreach ($c in (Read-Utf8Json $rcF).commodities) { [void]$entries.Add(@{ id = [string]$c.id; label = [string]$c.label; source = 'recipe-commodities.json' }) } }
$rbF = Join-Path $OutDir 'recipe-board-everyday.json'
if (Test-Path $rbF) { foreach ($r in (Read-Utf8Json $rbF).comparison) { [void]$entries.Add(@{ id = [string]$r.id; label = [string]$r.commodity; source = 'recipe-board-everyday.json' }) } }

$allow = @()
$alF = Join-Path $Root 'commodity-dupe-allowlist.json'
if (Test-Path $alF) { try { $allow = @((Read-Utf8Json $alF).allow) } catch { } }
# recipe-floor-id-map.json pairs are ALREADY-REVIEWED same-thing declarations: export-feed mechanically
# re-points each recipe spelling at its weekly twin, and rebid-ingredient exists for the unit-mismatched
# rest. Demanding they be registered a second time in the dupe allowlist would be two copies of one ruling
# (the two-copies trap), so the map itself is honored as review. First live run proved the point: 7 of 10
# suspects were map pairs (apple/apples, feta/feta-cheese, flour, worcestershire, cucumber, jalapeno,
# chipotle-in-adobo).
$mapF = Join-Path $Root 'recipe-floor-id-map.json'
if (Test-Path $mapF) {
  try {
    $mapDoc = Read-Utf8Json $mapF
    foreach ($p in $mapDoc.PSObject.Properties) {
      if ($p.Value -is [string] -and $p.Value) { $allow += @{ a = [string]$p.Name; b = [string]$p.Value } }
      elseif ($p.Value -and $p.Value.PSObject -and -not ($p.Value -is [string])) {
        foreach ($q in $p.Value.PSObject.Properties) { if ($q.Value -is [string] -and $q.Value) { $allow += @{ a = [string]$q.Name; b = [string]$q.Value } } }
      }
    }
  } catch { }
}

$sus = Find-DupeSuspects $entries $allow
$report = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); entries_scanned = $entries.Count
                      namespaces = @('commodities.json', 'recipe-commodities.json', 'recipe-board-everyday.json')
                      suspects = @($sus) }
$report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'commodity-dupes.json') -Encoding UTF8

if (@($sus).Count -eq 0) {
  Write-Output ("commodity-dupes: OK - {0} ids across 3 namespaces, no unreviewed near-duplicates" -f $entries.Count)
  Write-Output 'COMMODITY-DUPES-COMPLETE'
  exit 0
}
Write-Output ("commodity-dupes: {0} suspect pair(s) - the same food may be priced under two ids, which lets the two prices disagree while every per-file check reads green:" -f @($sus).Count)
foreach ($x in $sus) { Write-Output ("  {0} ({1})  vs  {2} ({3})  - {4}" -f $x.a, $x.a_source, $x.b, $x.b_source, $x.reason) }
Write-Output '  Review each: merge real duplicates (rebid consumers, drop the loser row), or record a written reason in commodity-dupe-allowlist.json.'
Write-Output 'COMMODITY-DUPES-COMPLETE'
exit 2
