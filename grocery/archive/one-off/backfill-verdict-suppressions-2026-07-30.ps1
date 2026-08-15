<#
  backfill-verdict-suppressions-2026-07-30.ps1 (one-off) - seed verdict-suppressions.json from the six
  historical verify-verdicts files.

  QUOTE-RECOVERED DROPS ONLY. A verdict names (commodity, store) but not the item; the only trustworthy
  witness for WHICH product was judged is the name quoted inside the reason. Resolving the quoteless ones
  through their week's comparison file is exactly the drift trap promote-verdicts fell into on 2026-07-30
  (6 of 13 proposed rules were built from the CORRECT replacement product). Measured coverage: 42 of 81
  historical drops carry a recoverable quote; the other 39 stay weekly judgments until re-judged under the
  new schema, which records them with certainty at apply time.

  LATEST WORD WINS: files are walked oldest -> newest, so a drop later re-reviewed as keep does not seed.
#>
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\ThriftyCrew\grocery'
. (Join-Path $root 'verdict-lib.ps1')
$outF = Join-Path $root 'verdict-suppressions.json'

$byKey = @{}
foreach ($vf in (Get-ChildItem (Join-Path $root 'out\verify-verdicts-*.json') | Sort-Object Name)) {
  $vj = Get-Content $vf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  $wk = [string]$vj.week_of
  foreach ($c in @($vj.verdicts)) {
    foreach ($e in @($c.entries)) {
      $judged = Get-VerdictQuotedItem ([string]$e.reason)
      if (-not $judged) { continue }
      $key = ([string]$c.id) + '|' + ([string]$e.store) + '|' + (Get-VerdictNorm $judged)
      $byKey[$key] = [pscustomobject]@{
        id = [string]$c.id; store = [string]$e.store; item_norm = (Get-VerdictNorm $judged); item = $judged
        week = $wk; reason = [string]$e.reason; source = 'quote-backfill'
        keep = ($e.keep -ne $false)
      }
    }
  }
}
$seed = @($byKey.Values | Where-Object { -not $_.keep } | Select-Object id, store, item_norm, item, week, reason, source | Sort-Object id, store, item_norm)
$obj = [ordered]@{
  readme = "Every confirmed DROP verdict ever made, keyed (id, store, normalised item), applied by verify-apply on EVERY run regardless of which week produced it. Exists because only the current week's verdict file used to be read, so the same wrong products returned as soon as their week rolled over - 18 previously-dropped cells were live again on 2026-07-29, three as crowns. Entries are added automatically when a drop's item identity is CONFIRMED (verdict item field or reason quote matches the cell), and removed automatically when a later keep verdict overturns one. Do not hand-edit item_norm; it is Get-VerdictNorm's output (verdict-lib.ps1)."
  updated = (Get-Date).ToString('s')
  suppressions = $seed
}
($obj | ConvertTo-Json -Depth 5) | Set-Content $outF -Encoding UTF8
Write-Output ("seeded " + @($seed).Count + " suppression(s) (of " + $byKey.Count + " quote-recovered verdicts; keeps excluded) -> " + $outF)
@($seed) | Group-Object id | Sort-Object Count -Descending | Select-Object -First 6 | ForEach-Object { Write-Output ("  " + $_.Count + "x " + $_.Name) }
