<#
  audit-multipack-size.ps1

  A row whose NAME says it is a multipack ("ReaLemon 100% Lemon Juice (2 pk)", "Member's Mark
  Distilled White Vinegar, 1 gal., 2 pk.") but whose SIZE records only ONE unit ("48 fl oz", "1 gal")
  is priced against the wrong quantity - the board charges the 2-pack price for a single bottle and
  the store looks up to 2x more expensive than it is. Sam's Club is the main offender (its whole
  catalogue is multipacks) but any store can do it.

  We flag any row where the name declares a pack count > 1 and the size does NOT, so the quantity
  used for per-unit is the single-unit size.

  Each hit is a CANDIDATE - it must be checked against the store page before changing, because some
  names carry a count that is NOT a size multiplier ("Hot Dogs 8 Count", 15 oz TOTAL).
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$hits = New-Object System.Collections.ArrayList

foreach ($f in Get-ChildItem (Join-Path $root 'out\regular\*-regular-*.json')) {
  $prefix = ($f.BaseName -replace '-regular-.*$', '')
  $newest = Get-ChildItem (Join-Path $root ('out\regular\' + $prefix + '-regular-*.json')) |
            Sort-Object Name -Descending | Select-Object -First 1
  if ($f.FullName -ne $newest.FullName) { continue }
  $doc = Get-Content $f.FullName -Raw | ConvertFrom-Json
  foreach ($d in $doc.deals) {
    $name = [string]$d.item; $size = [string]$d.size
    if (-not $name -or -not $size) { continue }
    # pack count declared in the NAME
    $pn = [regex]::Match($name.ToLower(), '(\d+)\s*(?:pk\b|pack\b)')
    if (-not $pn.Success) { continue }
    $packs = [int]$pn.Groups[1].Value
    if ($packs -le 1) { continue }
    # does the SIZE already carry that multiplier?
    $ps = [regex]::Match($size.ToLower(), '(\d+)\s*(?:x|pk\b|pack\b|ct\b|count\b)')
    if ($ps.Success -and ([int]$ps.Groups[1].Value) -gt 1) { continue }   # size already says "2 pk ..." - fine
    # size must contain a single unit amount for this to matter
    if ($size -notmatch '[\d.]+\s*(fl\s?oz|oz|lb|gal|qt|l|ml|g)\b') { continue }
    [void]$hits.Add([pscustomobject]@{ store=[string]$doc.store; item=$name; size=$size; packs=$packs; price=[string]$d.ad_price })
  }
}

Write-Output ("ROWS WHERE THE NAME SAYS 'N pack' BUT THE SIZE IS ONE UNIT: " + $hits.Count)
Write-Output ''
foreach ($h in ($hits | Sort-Object store, item)) {
  Write-Output ("  [{0,-12}] x{1}  size=[{2}]  {3}  {4}" -f $h.store, $h.packs, $h.size, $h.price, $h.item)
}
$hits | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root 'out\multipack-suspects.json') -Encoding UTF8
