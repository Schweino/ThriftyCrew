# ingredient-resolutions.ps1
# ---------------------------------------------------------------------------------------------------
# Remembers what an ingredient string resolved to, so the mapper stops re-deriving stable answers and
# the commodity-registrar is never asked the same question twice.
#
# IDENTITY ONLY - NEVER PRICE. This caches "shaved beef steak -> shaved-beef-steak, bid exists" and
# nothing else. Prices come from the board and change weekly; caching one would be how a stale number
# reaches a card. The `bid_exists` flag is a fact about the WIRING (is there a row in
# db\ingredients.json), not about the amount, and it is what lets the mapper hold a recipe BEFORE the
# writer is paid rather than after the auditor catches it - the R3 shift-left in the efficiency plan.
#
#   .\ingredient-resolutions.ps1 -Record -Term 'shaved beef steak' -ItemId shaved-beef-steak [-BidExists] [-Evidence '...'] [-By mapper]
#   .\ingredient-resolutions.ps1 -Query -Term 'shaved beef steak'         exit 3 when a prior ruling exists
#   .\ingredient-resolutions.ps1 -Invalidate -ItemId x    (a registrar ruling changed a commodity id)
#   .\ingredient-resolutions.ps1 -SelfTest
# ---------------------------------------------------------------------------------------------------
param(
  [switch]$Record, [switch]$Query, [switch]$Invalidate, [switch]$List, [switch]$SelfTest,
  [string]$Term = '', [string]$ItemId = '', [string]$Evidence = '', [string]$By = '',
  [switch]$BidExists, [string]$Store = '', [switch]$Json
)
$ErrorActionPreference = 'Stop'
$runRecord=[bool]$Record; $runQuery=[bool]$Query; $runInv=[bool]$Invalidate; $runSelfTest=[bool]$SelfTest; $runJson=[bool]$Json; $runBid=[bool]$BidExists

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
if (-not $Store) { $Store = Join-Path $mp 'db\ingredient-resolutions.json' }

function Get-TermKey {
  param([string]$T)
  if (-not $T) { return '' }
  # Normalise the incidental, keep the meaningful. "2 lbs Shaved Beef Steak," and "shaved beef steak"
  # are the same question; "beef steak" is NOT, so no word is ever dropped.
  $t = $T.ToLower().Trim()
  $t = $t -replace '[^a-z0-9 ]', ' '
  $t = $t -replace '\s+', ' '
  return $t.Trim()
}
function Read-Store { param([string]$P)
  if (-not (Test-Path $P)) { return @() }
  try { $d = Get-Content $P -Raw -Encoding utf8 | ConvertFrom-Json } catch { return @() }
  if ($d -and ($d.PSObject.Properties.Name -contains 'resolutions')) { return @($d.resolutions) }
  return @() }

if ($runSelfTest) {
  $bad=0
  function T([string]$n,[bool]$ok,[string]$got){ if($ok){Write-Output ("  ok    "+$n)}else{Write-Output ("  X     "+$n+"   got: "+$got); $script:bad++} }
  T 'case and punctuation are normalised away' ((Get-TermKey '  Shaved Beef Steak, ') -eq 'shaved beef steak') (Get-TermKey '  Shaved Beef Steak, ')
  T 'MUST FIRE  a DIFFERENT ingredient does not collide with a shorter one' ((Get-TermKey 'beef steak') -ne (Get-TermKey 'shaved beef steak')) 'collided'
  T 'internal whitespace collapses' ((Get-TermKey 'sour    cream') -eq 'sour cream') (Get-TermKey 'sour    cream')
  T 'an empty term keys to empty rather than throwing' ((Get-TermKey '') -eq '') 'threw'
  $tmp = Join-Path $env:TEMP ('ir-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    ([pscustomobject]@{ resolutions=@([pscustomobject]@{key='sumac';item_id='sumac';bid_exists=$false}) } | ConvertTo-Json -Depth 5) | Set-Content $tmp -Encoding utf8
    $b = @(Read-Store $tmp)
    T 'the store round-trips' ($b.Count -eq 1 -and $b[0].key -eq 'sumac') ([string]$b.Count)
    T 'MUST FIRE  bid_exists=false survives the round-trip as FALSE, not as absent' ($b[0].bid_exists -eq $false) ([string]$b[0].bid_exists)
    T 'a missing store reads as empty' ((@(Read-Store (Join-Path $env:TEMP 'nope-ir.json'))).Count -eq 0) 'not empty'
  } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force } }
  if ($bad -gt 0) { Write-Output ("ingredient-resolutions SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'ingredient-resolutions SELF-TEST PASS'
  Write-GuardComplete -Name 'ingredient-resolutions' -Summary 'selftest pass'; exit 0
}

$rows = @(Read-Store $Store)

function Save-Rows { param($R)
  $doc = [pscustomobject]@{
    _doc='Ingredient string -> commodity id, plus whether a bid is wired. Consulted by the mapper before it reasons and before it asks the commodity-registrar. IDENTITY ONLY - never a price.'
    _rule='Invalidated by any registrar ruling that changes a commodity id. bid_exists is a fact about db\ingredients.json wiring, refreshed by the mapper, and is what lets a recipe hold at `mapped` instead of dying at the audit.'
    updated=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); count=@($R).Count; resolutions=@($R) }
  $t = $Store + '.tmp'
  ($doc | ConvertTo-Json -Depth 6) | Set-Content -Path $t -Encoding utf8
  Move-Item -Path $t -Destination $Store -Force }

if ($runRecord) {
  $k = Get-TermKey $Term
  if (-not $k) { Write-Output 'ingredient-resolutions: -Record needs -Term'; exit 1 }
  $keep = @($rows | Where-Object { [string]$_.key -ne $k })
  $row = [pscustomobject]@{ key=$k; term=$Term; item_id=$ItemId; bid_exists=$runBid; evidence=$Evidence; by=$By; at=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') }
  Save-Rows @($keep + $row)
  Write-Output ("ingredient-resolutions: {0} -> {1}{2}" -f $k, $(if($ItemId){$ItemId}else{'(null)'}), $(if($runBid){' [bid wired]'}else{' [NO BID - recipe must hold at mapped]'}))
  exit 0
}
if ($runInv) {
  if (-not $ItemId) { Write-Output 'ingredient-resolutions: -Invalidate needs -ItemId'; exit 1 }
  $before = @($rows).Count
  $keep = @($rows | Where-Object { [string]$_.item_id -ne $ItemId })
  Save-Rows $keep
  Write-Output ("ingredient-resolutions: invalidated {0} row(s) for item_id '{1}'" -f ($before - @($keep).Count), $ItemId)
  exit 0
}
if ($runQuery) {
  $k = Get-TermKey $Term
  $r = @($rows | Where-Object { [string]$_.key -eq $k })[0]
  if (-not $r) { if($runJson){ '{"found":false}' } else { Write-Output ("ingredient-resolutions: no prior resolution for '{0}'" -f $k) }; exit 0 }
  if ($runJson) { ($r | ConvertTo-Json -Depth 4); exit 3 }
  Write-Output ("ingredient-resolutions: '{0}' -> {1}  bid_exists={2}  (by {3} on {4})" -f $r.key, $(if($r.item_id){$r.item_id}else{'(null)'}), $r.bid_exists, $r.by, $r.at)
  if ($r.evidence) { Write-Output ("  evidence: " + $r.evidence) }
  exit 3
}
if ($runJson) { ([pscustomobject]@{ count=@($rows).Count; resolutions=@($rows) } | ConvertTo-Json -Depth 6); exit 0 }
Write-Output ("ingredient-resolutions: {0} resolution(s)" -f @($rows).Count)
foreach ($r in @($rows | Sort-Object key)) { Write-Output ("  {0,-34} {1,-28} {2}" -f $r.key, $(if($r.item_id){$r.item_id}else{'(null)'}), $(if($r.bid_exists){'bid'}else{'NO BID'})) }
exit 0
