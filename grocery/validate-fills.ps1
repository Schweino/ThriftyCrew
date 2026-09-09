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
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param(
  # Resolved BELOW the block: under [CmdletBinding()] PS 5.1 expands $PSScriptRoot to '' inside a
  # param default, so this string became "\out\newitem-candidates.json" - a path off the drive root.
  [string]$FillsFile = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = $PSScriptRoot
if (-not $FillsFile) { $FillsFile = Join-Path $root 'out\newitem-candidates.json' }

# --- pull the live GLOBAL_EXCLUDE straight out of compare-deals.ps1 (no copy = no drift)
# THE EXCLUDE LIST IS A LIBRARY NOW (2026-09-09, backlog I82). The header's promise is unchanged and
# better kept: the rules cannot drift, because there is still exactly one copy - it just arrives through
# a dot-source rather than a regex over the engine's source text.
. (Join-Path $root 'global-exclude-lib.ps1')
$GLOBAL_EXCLUDE = Get-TcGlobalExclude
# NULL OR EMPTY, NOT 'FEWER THAN TWO'. @($null).Count is 1 in PowerShell, which is why this used
# to read -lt 2 - and that also refused the one-token lists the match-soundness fixtures drive on
# purpose. Name the two states being rejected rather than using a count as a proxy for them.
if ($null -eq $GLOBAL_EXCLUDE -or @($GLOBAL_EXCLUDE).Count -lt 1) { Write-Output 'FATAL: the global exclude list is empty or unreadable'; exit 2 }

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
