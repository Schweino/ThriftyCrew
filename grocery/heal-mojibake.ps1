<#
  heal-mojibake.ps1 - one-time backfill: repair product names that were corrupted BEFORE the ingest fix.

  Every builder now reads its capture as UTF-8 and repairs on ingest (see capture-lib.ps1), so new pulls are
  clean. But the corruption was baked into the BYTES of files already on disk, and compare-deals unions each
  store's captures across a 14-day window - so older files keep feeding mangled names onto the board until
  they age out. This repairs them in place instead of waiting two weeks.

  It is safe to re-run: Repair-Mojibake only touches strings carrying a mojibake signature that round-trip to
  a clean UTF-8 decode, and it is idempotent. Clean text - including legitimately accented brand names - is
  returned byte-identical.

  Usage: .\heal-mojibake.ps1            (dry run - lists what it would change)
         .\heal-mojibake.ps1 -Apply
#>
param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\income\grocery' }
. (Join-Path $root 'capture-lib.ps1')

$targets = @(
  'out\regular\*-regular-*.json'
  'out\sams\sams-deals-*.json'
  'out\bakers\bakers-deals-*.json'
  'out\fareway\fareway-deals-*.json'
)
$totalFiles = 0; $totalRows = 0
foreach ($glob in $targets) {
  foreach ($f in (Get-ChildItem (Join-Path $root $glob) -ErrorAction SilentlyContinue)) {
    if ($f.BaseName -notmatch '\d{4}-\d{2}-\d{2}$') { continue }   # skip rejects/meta side files
    try { $doc = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    if (-not $doc.PSObject.Properties['deals']) { continue }
    $n = 0
    foreach ($d in @($doc.deals)) {
      foreach ($col in @('item', 'name')) {
        if ($d.PSObject.Properties[$col]) {
          $before = [string]$d.$col
          $after = Repair-Mojibake $before
          if ($after -ne $before) { $d.$col = $after; $n++ }
        }
      }
    }
    if ($n -gt 0) {
      $totalFiles++; $totalRows += $n
      Write-Output ("  {0,-38} {1} name(s)" -f $f.Name, $n)
      if ($Apply) { ($doc | ConvertTo-Json -Depth 8) | Set-Content $f.FullName -Encoding UTF8 }
    }
  }
}
# product-urls.json has its own shape (items.<commodity>.<store>.name) and its own reason to be clean: that
# name is what the "See item" tile advertises, and audit-name-drift compares it WORD BY WORD against the board
# item. Mojibake on one side and not the other reads as a wrong product.
$puPath = Join-Path $root 'product-urls.json'
if (Test-Path $puPath) {
  $pu = Get-Content $puPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $pn = 0
  foreach ($cid in $pu.items.PSObject.Properties.Name) {
    foreach ($s in $pu.items.$cid.PSObject.Properties) {
      if ($s.Name -eq 'commodity') { continue }
      if ($s.Value -and $s.Value.PSObject.Properties['name']) {
        $before = [string]$s.Value.name
        $after = Repair-Mojibake $before
        if ($after -ne $before) { $s.Value.name = $after; $pn++ }
      }
    }
  }
  if ($pn -gt 0) {
    $totalFiles++; $totalRows += $pn
    Write-Output ("  {0,-38} {1} link name(s)" -f 'product-urls.json', $pn)
    if ($Apply) { ($pu | ConvertTo-Json -Depth 8) | Set-Content $puPath -Encoding UTF8 }
  }
}

if ($totalRows -eq 0) { Write-Output 'heal-mojibake: nothing to repair - every store file is clean.'; exit 0 }
Write-Output ("heal-mojibake: {0} name(s) across {1} file(s)" -f $totalRows, $totalFiles)
if (-not $Apply) { Write-Output 'DRY RUN. Pass -Apply to write.' }
