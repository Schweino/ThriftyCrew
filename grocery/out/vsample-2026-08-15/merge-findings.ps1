# Merge the per-store BLIND result CSVs into the findings CSV that adjudicate-blind-findings.ps1 wants.
# Store agents wrote: ticket,seq,verdict,found_product,found_price,note
# Adjudicator wants:  ticket,found_product,found_price,found_pack,availability,reachable,note
# The agent "verdict" here is NOT a board verdict (they never saw the board). It only tells us whether
# they reached the store and whether the store sells the thing.
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path (Split-Path -Parent $dir) 'verification-findings-2026-08-15.csv'

$rows = New-Object System.Collections.ArrayList
$seen = @{}
foreach ($f in (Get-ChildItem $dir -Filter '*.csv' | Sort-Object Name)) {
  $txt = ((Get-Content $f.FullName -Raw -Encoding UTF8) + '')
  $lines = @($txt -split "`r?`n" | Where-Object { -not ($_ -match '^\s*#') -and $_.Trim().Length -gt 0 })
  if ($lines.Count -lt 2) { Write-Output ('  SKIP (no rows): ' + $f.Name); continue }
  $parsed = @($lines | ConvertFrom-Csv)
  $n = 0
  foreach ($r in $parsed) {
    $t = ([string]$r.ticket).Trim()
    if ($t -eq '') { continue }
    if ($seen.ContainsKey($t)) { Write-Output ('  DUPLICATE ticket ' + $t + ' in ' + $f.Name + ' - kept the first'); continue }
    $seen[$t] = $true
    $v = ([string]$r.verdict).Trim().ToLower()
    $reach = if ($v -eq 'unverifiable') { 'no' } else { 'yes' }
    $avail = if ($v -eq 'missing') { 'not-sold' } else { 'sold' }
    [void]$rows.Add([pscustomobject]@{
      ticket        = $t
      found_product = ([string]$r.found_product).Trim()
      found_price   = ([string]$r.found_price).Trim()
      found_pack    = ''
      availability  = $avail
      reachable     = $reach
      note          = ([string]$r.note).Trim()
    })
    $n++
  }
  Write-Output ('  ' + $f.Name + ': ' + $n + ' row(s)')
}
$rows | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8
Write-Output ('merged ' + $rows.Count + ' finding(s) -> ' + $out)
