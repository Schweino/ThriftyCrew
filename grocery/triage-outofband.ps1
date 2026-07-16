<#
  triage-outofband.ps1 - sub-diagnose the OUT-OF-BAND bucket from triage-coverage-gaps.ps1.

  OUT-OF-BAND means the engine matched the product, DID compute a per-unit, and then Test-Band rejected it as
  implausible - so the cell was dropped rather than published. That is the band doing its job, and the question
  is which of two things it caught:

    PARSE-BUG    the per-unit is wrong because the row's price/size were misread (a pack price on a one-unit
                 size, a per-lb price treated as a pack price...). The number is a lie; fix the ROW, not the band.
    REAL-OUTLIER the per-unit is right and the product genuinely costs that much (organic, tiny premium jar,
                 a single-serve cup against a bulk commodity). Not our item - allowlist it.
    BAND-TOO-TIGHT the per-unit is right and normal, and the band is simply wrong for this commodity.

  Reads out\flagged-<date>.json, which is where compare-deals records every out-of-band row WITH the band it
  failed and the price_text/size_text it was computed from - the engine's own evidence, not a re-derivation.
  Prints the ratio vs the band so the shape of the error is visible: an exact 2x/3x/12x/16x says PARSE-BUG loudly.
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

$gapRows = @((Get-Content (Join-Path $OutDir 'gap-triage.json') -Raw | ConvertFrom-Json).rows) | Where-Object { $_.cause -eq 'OUT-OF-BAND' }
$fF = Get-ChildItem (Join-Path $OutDir 'flagged-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$fl = Get-Content $fF.FullName -Raw | ConvertFrom-Json
$rows = if ($fl.flagged) { @($fl.flagged) } elseif ($fl.rows) { @($fl.rows) } else { @($fl) }
$idx = @{}
foreach ($r in $rows) { $idx[([string]$r.id + '|' + [string]$r.store + '|' + [string]$r.name)] = $r }

Write-Output ("triage-outofband: " + $gapRows.Count + " gap(s) rejected by the band   (flagged file: " + $fF.Name + ", " + $rows.Count + " rows)")
Write-Output ''
$out = New-Object System.Collections.Generic.List[object]
foreach ($g in $gapRows) {
  $k = [string]$g.commodity + '|' + [string]$g.store + '|' + [string]$g.candidate
  $r = if ($idx.ContainsKey($k)) { $idx[$k] } else { $null }
  if (-not $r) { $out.Add([pscustomobject]@{ commodity = $g.commodity; store = $g.store; note = 'NOT-IN-FLAGGED' }); continue }
  $lo = 0.0; $hi = 0.0
  $b = [string]$r.band -split '-'
  [void][double]::TryParse($b[0], [ref]$lo); [void][double]::TryParse($b[-1], [ref]$hi)
  $pu = [double]$r.unit_price
  $ratio = if ($hi -gt 0 -and $pu -gt $hi) { [math]::Round($pu / $hi, 2) } elseif ($lo -gt 0 -and $pu -lt $lo) { -[math]::Round($lo / $pu, 2) } else { 0 }
  $out.Add([pscustomobject]@{ commodity = [string]$r.id; store = [string]$r.store; unit = [string]$r.unit; pu = $pu; band = [string]$r.band; ratio = $ratio; price_text = [string]$r.price_text; size_text = [string]$r.size_text; name = [string]$r.name })
}
([ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); count = $out.Count; rows = $out } | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $OutDir 'outofband-triage.json') -Encoding UTF8

foreach ($r in ($out | Sort-Object { -[math]::Abs($_.ratio) })) {
  if ($r.note) { Write-Output ("  " + $r.commodity + ' / ' + $r.store + '  ' + $r.note); continue }
  $x = if ($r.ratio -gt 0) { "{0}x ABOVE band" -f $r.ratio } elseif ($r.ratio -lt 0) { "{0}x BELOW band" -f [math]::Abs($r.ratio) } else { 'in band?' }
  Write-Output ("  {0,-20}{1,-13}pu=\${2,-9} band={3,-14}{4}" -f $r.commodity, $r.store, $r.pu, $r.band, $x)
  Write-Output ("       price=[{0}]  size=[{1}]" -f $r.price_text, $r.size_text)
  Write-Output ("       <- " + $r.name)
}
