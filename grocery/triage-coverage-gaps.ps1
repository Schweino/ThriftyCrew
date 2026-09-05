<#
  triage-coverage-gaps.ps1 - for every gap audit-coverage-gaps.ps1 reports, say WHY the engine dropped it.

  audit-coverage-gaps tells you a store HAS a matching product but is off the board. It does not tell you why,
  and the why decides the fix - or whether there is a bug at all. A gap is one of:

    NO-INCLUDE     the strict include never matched this name (the store names it differently). THE REAL BUG
                   CLASS - Sam's "Boneless and Skinless", Aldi "Kirkwood Family Pack Chicken Breasts". Fix: widen.
    GLOBAL-EXCL    include matched, but a GLOBAL_EXCLUDE token (sauce/frozen/canned/...) blocked it. Usually
                   correct (it IS a prepared form); occasionally needs relax_global on that commodity.
    OWN-EXCL       include matched, but the commodity's own exclude blocked it. Usually correct.
    STOLEN         include matched, but an EARLIER commodity in the array claimed the name first-match-wins.
                   Either a real mis-match to fix, or the other commodity is the right owner and this is no gap.
    UNPRICED       matched and owned, but Get-UnitPrice could not derive a per-unit (no usable size basis).
                   Not a rule bug - a data/size bug.
    OUT-OF-BAND    matched and priced, but the per-unit fell outside the commodity's sanity band, so the engine
                   dropped it. Usually a real parse/quantity bug in the row, NOT something to fix by widening.
    LOOSE-FP       the gap audit's LOOSENED regex matched but the strict one never could, and the name plainly
                   is not this commodity. A false alarm - allowlist it, do not widen anything.

  Read-only. Writes out\gap-triage.json and prints a cause histogram.
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
# NB: do NOT write @(... | ConvertFrom-Json) on a bare JSON array. PowerShell 5.1 emits the deserialized array
# as ONE object, so @() wraps the whole array as a single element: the foreach below then runs ONCE with $c =
# every commodity at once, $c.include member-enumerates to 829 patterns, and [string]$c.id is all 378 ids
# concatenated - so the target id never matches and EVERY gap reports NO-INCLUDE. That is exactly what this
# script did on its first run, and acting on it would have meant ~96 rule edits chasing a fabricated diagnosis.
# compare-deals.ps1 and audit-coverage-gaps.ps1 get this right by omitting the @().
$commods = Read-JsonFile (Join-Path $root 'commodities.json')
if (@($commods).Count -lt 2) { throw "commodities.json did not deserialize to a list (got $(@($commods).Count)) - the PS 5.1 ConvertFrom-Json array trap; every diagnosis would be wrong." }
$gaps = @((Read-JsonFile (Join-Path $OutDir 'coverage-gaps.json')).gaps)

# --- mirror the engine EXACTLY (same list, same order, same normalization) -------------------------------
$src = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
$m = [regex]::Match($src, '\$GLOBAL_EXCLUDE\s*=\s*@\((?<body>[\s\S]*?)\r?\n\)')
$GLOBAL_EXCLUDE = Invoke-Expression ('@(' + $m.Groups['body'].Value + ')')
function Get-MatchTexts([string]$name) {
  $n = $name.ToLower()
  $v = $n -replace ',?\s*priced per\s+\w+', ''
  $v = (($v -replace '\band\b', ' ') -replace '\s{2,}', ' ').Trim()
  return , @($n, $v)
}
# returns @{ owner=<id or ''>; reason=<why THIS commodity did not get it> } for a given target commodity
function Explain([string]$name, [string]$targetId) {
  $texts = Get-MatchTexts $name
  $n = $texts[0]
  $ghits = @(); foreach ($g in $GLOBAL_EXCLUDE) { if ($n -match $g) { $ghits += $g } }
  $owner = ''
  $targetIncluded = $false; $targetGlobal = ''; $targetOwnEx = ''
  foreach ($c in $commods) {
    $hit = $false
    foreach ($inc in $c.include) { foreach ($t in $texts) { if ($t -match $inc) { $hit = $true; break } }; if ($hit) { break } }
    if (-not $hit) { continue }
    $blockedG = ''
    if ($ghits.Count) {
      $relax = @($c.relax_global | Where-Object { $_ })
      foreach ($g in $ghits) { if ($relax -notcontains $g) { $blockedG = $g; break } }
    }
    $blockedE = ''
    if (-not $blockedG) { foreach ($e in $c.exclude) { if ($n -match $e) { $blockedE = $e; break } } }
    if ([string]$c.id -eq $targetId) { $targetIncluded = $true; $targetGlobal = $blockedG; $targetOwnEx = $blockedE }
    if (-not $blockedG -and -not $blockedE -and -not $owner) { $owner = [string]$c.id }
  }
  if (-not $targetIncluded) { return @{ cause = 'NO-INCLUDE'; owner = $owner; detail = '' } }
  if ($targetGlobal) { return @{ cause = 'GLOBAL-EXCL'; owner = $owner; detail = $targetGlobal } }
  if ($targetOwnEx) { return @{ cause = 'OWN-EXCL'; owner = $owner; detail = $targetOwnEx } }
  if ($owner -and $owner -ne $targetId) { return @{ cause = 'STOLEN'; owner = $owner; detail = $owner } }
  return @{ cause = 'MATCHED-BUT-OFF-BOARD'; owner = $owner; detail = '' }   # priced/band/unit issue, see candidates
}

# candidates-<date>.json records what the engine matched + whether it could price it
$candF = Get-ChildItem (Join-Path $OutDir 'candidates-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$cand = @{}
if ($candF) {
  foreach ($c in (Read-JsonFile $candF.FullName).commodities) {
    foreach ($x in $c.candidates) { $cand[([string]$c.id + '|' + [string]$x.store + '|' + [string]$x.name)] = $x }
  }
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($g in $gaps) {
  $e = Explain ([string]$g.candidate) ([string]$g.commodity)
  $cause = $e.cause
  if ($cause -eq 'MATCHED-BUT-OFF-BOARD') {
    $k = [string]$g.commodity + '|' + [string]$g.store + '|' + [string]$g.candidate
    if ($cand.ContainsKey($k)) { $cause = if ($cand[$k].basis -eq 'OUT-OF-BAND') { 'OUT-OF-BAND' } elseif ($null -eq $cand[$k].unit_price) { 'UNPRICED' } else { 'ON-BOARD?' } }
  }
  $rows.Add([pscustomobject]@{ commodity = [string]$g.commodity; store = [string]$g.store; candidate = [string]$g.candidate; cause = $cause; owner = $e.owner; detail = $e.detail })
}
([ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); count = $rows.Count; rows = $rows } | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $OutDir 'gap-triage.json') -Encoding UTF8

Write-Output ("triage-coverage-gaps: " + $rows.Count + " gap(s)")
Write-Output ''
Write-Output 'CAUSE HISTOGRAM'
$rows | Group-Object cause | Sort-Object Count -Descending | ForEach-Object { Write-Output ("  {0,-24}{1}" -f $_.Name, $_.Count) }
Write-Output ''
Write-Output 'NO-INCLUDE (the real bug class - store names it differently than our rule expects):'
foreach ($r in ($rows | Where-Object { $_.cause -eq 'NO-INCLUDE' } | Sort-Object commodity)) {
  Write-Output ("  {0,-22}{1,-13}{2}" -f $r.commodity, $r.store, $r.candidate)
}
