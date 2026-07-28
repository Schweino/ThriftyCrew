<#
  audit-pack-basis.ps1 - catches the MULTIPACK TOTAL read as an EACH-SIZE (2026-07-28).

  The engine's count-first idiom ("24 ct 16.9 fl oz") means 24 bottles OF 16.9 oz, so it multiplies to a
  405.6 oz total. That is right for water, vinegar and grits. It is WRONG when the store already printed the
  pack TOTAL after the count: Sam's "Pledge Furniture Polish, 3 ct., 29 oz." is three 9.7 oz cans totalling
  29 oz, and multiplying gave 87 oz -> $0.14/oz, which made Sam's the cheapest furniture polish in Omaha at
  a third of the real price. Text alone cannot tell the two apart, so this audit uses ARITHMETIC:

    when the multiplied reading makes a cell a large outlier under every other store, but the un-multiplied
    (pack-total) reading would sit in the normal range, the multiply is what created the outlier.

  That is a fingerprint, not a guess - and it stays quiet for water/vinegar/grits, whose bulk cells are
  cheap in BOTH readings. Advisory by design (exit 0 with findings, 2 only on -Strict): a real bulk buy can
  trip it, so it names the cells for a human/triage decision instead of silently dropping a price.

  Usage: audit-pack-basis.ps1 [-CompareFile <path>] [-Strict]
#>
param([string]$CompareFile = "", [switch]$Strict)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'out'
if (-not $CompareFile) {
  $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
}
$doc = Get-Content $CompareFile -Raw | ConvertFrom-Json

# how far under the next-cheapest store counts as "an outlier this audit should explain"
$OUTLIER = 0.35
$findings = @()

foreach ($r in $doc.comparison) {
  $rows = @($r.stores | Where-Object { [double]$_.per_unit -gt 0 })
  if ($rows.Count -lt 2) { continue }
  $ranked = @($rows | Sort-Object { [double]$_.per_unit })
  foreach ($s in $ranked) {
    $size = [string]$s.size
    # the count-first idiom the engine multiplies on
    $m = [regex]::Match($size.ToLower(), '^\s*(\d+(?:\.\d+)?)\s*[- ]?\s*(?:ct|count|pk|packs?)\D+(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|ml|gal|gallon|qt|quart|pt|pint|lbs?|pound)\b')
    if (-not $m.Success) { continue }
    $cnt = [double]$m.Groups[1].Value
    if ($cnt -le 1) { continue }
    $published = [double]$s.per_unit
    # the alternative reading: the printed size was the pack TOTAL, so the price divides by it, not by count*it
    $asTotal = $published * $cnt
    # cheapest OTHER store on this commodity
    $others = @($ranked | Where-Object { $_.store -ne $s.store } | ForEach-Object { [double]$_.per_unit })
    if ($others.Count -eq 0) { continue }
    $peer = ($others | Sort-Object)[0]
    if ($peer -le 0) { continue }
    $underNow  = (($peer - $published) / $peer)
    $underThen = (($peer - $asTotal) / $peer)
    # published reading is a big outlier; the pack-total reading is NOT -> the multiply made the outlier
    if ($underNow -ge $OUTLIER -and $underThen -lt $OUTLIER) {
      $findings += [pscustomobject]@{
        id = [string]$r.id; commodity = [string]$r.commodity; store = [string]$s.store
        unit = [string]$r.unit; published = [math]::Round($published,4)
        as_pack_total = [math]::Round($asTotal,4); peer_cheapest = [math]::Round($peer,4)
        count = $cnt; size = $size; ad = [string]$s.ad; item = [string]$s.item
      }
    }
  }
}

$rep = Join-Path $OutDir 'pack-basis-audit.json'
([pscustomobject]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); compare_file = (Split-Path $CompareFile -Leaf); finding_count = $findings.Count; findings = $findings } |
  ConvertTo-Json -Depth 5) | Set-Content $rep -Encoding UTF8

if ($findings.Count -eq 0) { Write-Output 'pack-basis: ok - no multipack cell owes its cheapest-in-Omaha rank to the count multiply'; exit 0 }
Write-Output ("pack-basis: " + $findings.Count + " cell(s) are cheapest ONLY because a pack count was multiplied into the size - verify the size is per-item, not the pack total:")
foreach ($f in $findings) {
  Write-Output ("  {0,-24} {1,-12} published {2}/{3} vs {4} as a pack total (peer {5}) | size '{6}' | {7}" -f `
    $f.id, $f.store, $f.published, $f.unit, $f.as_pack_total, $f.peer_cheapest, $f.size, $f.item)
}
Write-Output ("  report: " + $rep)
if ($Strict) { exit 2 }
exit 0
