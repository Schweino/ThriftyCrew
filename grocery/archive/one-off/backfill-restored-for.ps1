<#
  backfill-restored-for.ps1 - one-off: stamp `restored_for` (the commodity a restored row exists to fix) onto
  rows written before heal-missing-products started recording it. Matches each restored product name back to
  the product-urls entry it came from. Safe to re-run; rows that already carry the field are left alone.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$pd = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items

$n = 0; $unmatched = 0
foreach ($f in (Get-ChildItem (Join-Path $root 'out\regular\*-regular-*.json') | Where-Object { $_.BaseName -match '-regular-\d{4}-\d{2}-\d{2}$' })) {
  $doc = Get-Content $f.FullName -Raw | ConvertFrom-Json
  $changed = $false
  foreach ($d in $doc.deals) {
    if ((-not $d.restored) -or $d.restored_for) { continue }
    $st = [string]$d.store
    $nm = ([string]$d.item).ToLower().Trim()
    $hit = $null
    foreach ($p in $pd.PSObject.Properties) {
      $e = $p.Value.$st
      if ($e -and $e.name -and ((([string]$e.name).ToLower().Trim()) -eq $nm)) { $hit = $p.Name; break }
    }
    if ($hit) {
      $d | Add-Member -NotePropertyName restored_for -NotePropertyValue $hit -Force
      $changed = $true; $n++
    } else {
      $unmatched++
      Write-Output ("  no product-urls entry for [{0}] {1} - cannot say which commodity it was restored for" -f $st, [string]$d.item)
    }
  }
  if ($changed) { ($doc | ConvertTo-Json -Depth 6) | Set-Content $f.FullName -Encoding UTF8 }
}
Write-Output ("stamped restored_for on $n row(s); $unmatched could not be traced")
