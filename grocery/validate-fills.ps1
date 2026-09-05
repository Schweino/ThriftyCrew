<#
  validate-fills.ps1 - the guard against a fill row hijacking a DIFFERENT commodity's board cell.

  WHY THIS EXISTS: compare-deals' Match-Category walks $commodities in ARRAY ORDER and the FIRST
  commodity whose include matches (and whose exclude does not) wins the row. So a product name is
  not "owned" by the commodity we searched for - it is owned by whoever matches it first.

  Two real examples caught by this script on 2026-07-14:
    - "Great Value Bathroom Cleaner with Bleach"  -> we searched shower-cleaner, but `bleach`
      matches first, so adding that row would have silently overwritten Walmart's BLEACH cell.
    - "Fabuloso 2X Multi-Purpose Cleaner ... Floor Cleaner" -> `all-purpose-cleaner` matches first.

  So: every candidate fill must be run through the REAL matcher and must resolve to the commodity
  we intended. Anything else is rejected, and we fall through to the next-cheapest candidate.

  To guarantee the rules never drift, GLOBAL_EXCLUDE is parsed out of compare-deals.ps1 itself
  rather than copy-pasted here.
#>
param(
  [string]$FillsFile = "$PSScriptRoot\out\newitem-candidates.json"
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = $PSScriptRoot

# --- pull the live GLOBAL_EXCLUDE straight out of compare-deals.ps1 (no copy = no drift)
$src = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
$m = [regex]::Match($src, '\$GLOBAL_EXCLUDE\s*=\s*@\((?<body>[\s\S]*?)\r?\n\)')
if (-not $m.Success) { Write-Output 'FATAL: could not parse $GLOBAL_EXCLUDE from compare-deals.ps1'; exit 2 }
$GLOBAL_EXCLUDE = Invoke-Expression ('@(' + $m.Groups['body'].Value + ')')

$commodities = Read-JsonFile (Join-Path $root 'commodities.json')

function Match-Category($name) {
  $n = $name.ToLower()
  $ghits = @(); foreach ($g in $GLOBAL_EXCLUDE) { if ($n -match $g) { $ghits += $g } }
  foreach ($c in $commodities) {
    $hit = $false
    foreach ($inc in $c.include) { if ($n -match $inc) { $hit = $true; break } }
    if (-not $hit) { continue }
    if ($ghits.Count) {
      $relax = @($c.relax_global | Where-Object { $_ })
      $blocked = $false
      foreach ($g in $ghits) { if ($relax -notcontains $g) { $blocked = $true; break } }
      if ($blocked) { continue }
    }
    $bad = $false
    foreach ($exc in $c.exclude) { if ($n -match $exc) { $bad = $true; break } }
    if ($bad) { continue }
    return $c.id
  }
  return $null
}

$doc = Read-JsonFile $FillsFile
$ok = New-Object System.Collections.ArrayList
$rej = New-Object System.Collections.ArrayList

# candidates are grouped: { store, id, cands: [ {item, price, size, per} ... ] } cheapest-first
foreach ($g in $doc.candidates) {
  $picked = $null
  foreach ($c in $g.cands) {
    $owner = Match-Category ([string]$c.item)
    if ($owner -eq $g.id) { $picked = $c; break }
    $ownerLabel = '(no match)'
    if ($owner) { $ownerLabel = $owner }
    [void]$rej.Add([pscustomobject]@{ store=$g.store; want=$g.id; item=[string]$c.item; owner=$ownerLabel })
  }
  if ($picked) {
    [void]$ok.Add([pscustomobject]@{ store=$g.store; id=$g.id; item=[string]$picked.item; price=[double]$picked.price; size=[string]$picked.size })
  }
}

Write-Output ("ACCEPTED  {0}" -f $ok.Count)
foreach ($r in $ok) { Write-Output ("  {0,-12} {1,-19} {2}  `${3}" -f $r.store, $r.id, $r.item.Substring(0,[Math]::Min(46,$r.item.Length)), $r.price.ToString('0.00')) }
Write-Output ''
Write-Output ("REJECTED (would have landed in the WRONG commodity)  {0}" -f $rej.Count)
foreach ($r in $rej) { Write-Output ("  {0,-12} want={1,-18} -> would match '{2}'  [{3}]" -f $r.store, $r.want, $r.owner, $r.item.Substring(0,[Math]::Min(42,$r.item.Length))) }

$out = Join-Path $root 'out\newitem-accepted.json'
@{ verified=(Get-Date -Format 'yyyy-MM-dd'); accepted=$ok.ToArray(); rejected=$rej.ToArray() } | ConvertTo-Json -Depth 6 | Set-Content $out -Encoding UTF8
Write-Output ''
Write-Output ("saved -> " + $out)
