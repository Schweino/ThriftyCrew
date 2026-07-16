<#
  triage-unpriced.ps1 - sub-diagnose the UNPRICED bucket from triage-coverage-gaps.ps1.

  "UNPRICED" means the engine matched the product to the right commodity but Get-UnitPrice could not derive a
  per-unit. That is NOT a rule bug and must never be "fixed" by widening anything.

  READ THE CANDIDATES FILE, NOT THE SOURCE FILES. candidates-<date>.json records price_text/size_text EXACTLY as
  the engine saw them. My first version re-looked-up each product in the raw source files by (store|name) and
  took the first hit - but a store carries several rows under one name, so it reported Hy-Vee "Hass Avocados" as
  size=[each] (FIXABLE!) when the row the ENGINE priced was size=[bag] at $4.00 - correctly unpriced, because a
  bag with no count cannot yield a per-avocado price. A diagnosis built from different data than the engine used
  is a fiction. Same lesson as the probe that missed the rotisserie theft: read what the engine reads.

  Sub-causes:
    NO-COUNT-BAG   an each/dozen commodity priced as a bag/package with no count. Unpriceable, correctly.
    UNIT-MISMATCH  the store sells by weight, the commodity is per each (or vice-versa). Unpriceable, correctly.
    NO-SIZE        no size at all.
    NO-PRICE       no parseable price (a multibuy with no regular, etc.).
    FIXABLE        a compatible size EXISTS and the engine still could not price it -> a real Get-UnitPrice bug.
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$commods = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
if (@($commods).Count -lt 2) { throw 'ConvertFrom-Json array trap - see triage-coverage-gaps.ps1' }
$unit = @{}; foreach ($c in $commods) { $unit[[string]$c.id] = [string]$c.unit }

$gapRows = @((Get-Content (Join-Path $OutDir 'gap-triage.json') -Raw | ConvertFrom-Json).rows) | Where-Object { $_.cause -eq 'UNPRICED' }
$candF = Get-ChildItem (Join-Path $OutDir 'candidates-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$cand = @{}
foreach ($c in (Get-Content $candF.FullName -Raw | ConvertFrom-Json).commodities) {
  foreach ($x in $c.candidates) { $cand[([string]$c.id + '|' + [string]$x.store + '|' + [string]$x.name)] = $x }
}

$WEIGHT = '\boz\b|\bounces?\b|\blbs?\b|\bpounds?\b|\bgal(lon)?s?\b|\bqt\b|\bquarts?\b|\bpt\b|\bpints?\b|\bml\b|\bliters?\b|\bg\b|\bgrams?\b|\bfl\s*oz\b'
$COUNT = '\bct\b|\bcount\b|\bea\b|\beach\b|\bpk\b|\bpacks?\b|\bdozen\b|\bdoz\b'
$BAG = '\bbag\b|\bpackage\b|\bpkg\b|\bbunch\b|\bbox\b|\bcontainer\b|\bclamshell\b'

$out = New-Object System.Collections.Generic.List[object]
foreach ($r in $gapRows) {
  $k = [string]$r.commodity + '|' + [string]$r.store + '|' + [string]$r.candidate
  $x = if ($cand.ContainsKey($k)) { $cand[$k] } else { $null }
  $u = $unit[[string]$r.commodity]
  if (-not $x) { $out.Add([pscustomobject]@{ commodity = $r.commodity; store = $r.store; unit = $u; price_text = ''; size_text = ''; candidate = $r.candidate; sub = 'NOT-IN-CANDIDATES' }); continue }
  $pt = [string]$x.price_text; $st = [string]$x.size_text
  $sub = ''
  if (-not ($pt -match '\d')) { $sub = 'NO-PRICE' }
  elseif (-not $st) { $sub = 'NO-SIZE' }
  elseif ($u -in @('each', 'dozen')) {
    if ($st -match $COUNT) { $sub = 'FIXABLE' }
    elseif ($st -match $BAG) { $sub = 'NO-COUNT-BAG' }
    elseif ($st -match $WEIGHT) { $sub = 'UNIT-MISMATCH' }
    else { $sub = 'NO-SIZE' }
  } else {
    if ($st -match $WEIGHT) { $sub = 'FIXABLE' }
    elseif ($st -match $BAG) { $sub = 'NO-COUNT-BAG' }
    else { $sub = 'UNIT-MISMATCH' }
  }
  $out.Add([pscustomobject]@{ commodity = [string]$r.commodity; store = [string]$r.store; unit = $u; price_text = $pt; size_text = $st; candidate = [string]$r.candidate; sub = $sub })
}
([ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); count = $out.Count; rows = $out } | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $OutDir 'unpriced-triage.json') -Encoding UTF8

Write-Output ("triage-unpriced: " + $out.Count + " UNPRICED gap(s)  (diagnosed from what the ENGINE saw)")
Write-Output ''
$out | Group-Object sub | Sort-Object Count -Descending | ForEach-Object { Write-Output ("  {0,-20}{1}" -f $_.Name, $_.Count) }
Write-Output ''
Write-Output 'FIXABLE (compatible size present, engine still could not price - real Get-UnitPrice bugs):'
$fx = @($out | Where-Object { $_.sub -eq 'FIXABLE' } | Sort-Object commodity)
if (-not $fx.Count) { Write-Output '  (none)' }
foreach ($r in $fx) {
  Write-Output ("  {0,-20}{1,-13}unit={2,-6}price=[{3}]  size=[{4}]" -f $r.commodity, $r.store, $r.unit, $r.price_text, $r.size_text)
  Write-Output ("      <- " + $r.candidate)
}
