<#
  fix-linkpu-multipack.ps1

  THE BUG (live on the board): Fareway bottled water published at $3.87 EACH - that is the price of
  the whole 24-pack charged as a single bottle. Same for Fareway microwave popcorn ($2.99 for one bag
  instead of $0.9967).

  WHY: LinkPU() derives a per-unit from the LINK's size field only. For these products the size field
  is literally "each" (one package) and the pack count (24 Pack, 3 Pack) lives only in the NAME. With
  no count, LinkPU returns the whole package price as the per-item price. generate-board-overrides
  then PINS that number, and the pin BEATS the engine - so the absurd value publishes and no amount of
  fixing the store data changes it.

  LinkPU is duplicated in 4 files and the header says to keep them in lockstep, so all 4 are patched
  identically: LinkPU now takes the product NAME and, for an 'each' commodity whose size carries no
  count, reads the pack count from the name.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$files = @('audit-board-consistency.ps1','audit-link-price-match.ps1','build-deals-page.ps1','generate-board-overrides.ps1')

$oldSig = 'function LinkPU([string]$size, [string]$unit, [double]$price) {'
$newSig = @'
function LinkPU([string]$size, [string]$unit, [double]$price, [string]$name = '') {
'@

# inserted right after the bare-unit fallback, before the switch
$oldPk  = '  $pk = [regex]::Match($s, ''([0-9]+)\s*(pk|pack)\b''); if ($pk.Success -and $n -and ($un -match ''^(oz|lbs?|gal)$'')) { $n = $n * [double]$pk.Groups[1].Value }'
$newPk  = @'
  $pk = [regex]::Match($s, '([0-9]+)\s*(pk|pack)\b'); if ($pk.Success -and $n -and ($un -match '^(oz|lbs?|gal)$')) { $n = $n * [double]$pk.Groups[1].Value }
  # MULTIPACK IN THE NAME: a link whose size is just "each" but whose NAME says "24 Pack" is 24 items,
  # not 1. Without this the whole pack price is published as the per-item price (Fareway bottled water
  # went out at $3.87 EACH). Only for 'each' commodities, and only when the size carries no count.
  if ($unit -eq 'each' -and $name -and (($null -eq $n) -or ($n -eq 1))) {
    $pn = [regex]::Match(([string]$name).ToLower(), '([0-9]+)\s*(?:pk\b|pack\b|ct\b|count\b)')
    if ($pn.Success) {
      $cnt = [double]$pn.Groups[1].Value
      if ($cnt -gt 1) { return $price / $cnt }
    }
  }
'@

foreach ($f in $files) {
  $p = Join-Path $root $f
  $t = Get-Content $p -Raw
  $before = $t
  if ($t.Contains($oldSig)) { $t = $t.Replace($oldSig, $newSig.TrimEnd("`r","`n")) }
  if ($t.Contains($oldPk))  { $t = $t.Replace($oldPk,  $newPk.TrimEnd("`r","`n")) }
  if ($t -ne $before) { Set-Content $p $t -Encoding UTF8; Write-Output ("  patched LinkPU -> $f") }
  else { Write-Output ("  !! NO CHANGE (pattern not found) -> $f") }
}
