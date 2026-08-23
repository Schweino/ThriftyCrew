# audit-carriage.ps1 - the standing watch on "does Omaha still carry what our recipes are made of?"
#
# WHY (2026-08-22). Carriage is enforced at the two doors that matter - cost-recipes.ps1 records it and
# feed-covers-published.ps1 / publish.ps1 refuse on it. Both are EVENT-driven: they fire when something
# is costed or published. Nothing watched the standing state, and carriage is not static:
#
#   * a store drops a product and a live recipe silently becomes unmakeable. TEN bids in live use are
#     carried by exactly ONE store (achiote-paste and dried-ancho-chiles carry 8 recipes each). One
#     delisting is one silent breakage, and nothing would have said so until the next recost.
#   * the reverse, which is the whole reason the four recipes were DRAFTED and not deleted: an UNKNOWN
#     ingredient turns out to be carried after all once somebody searches the right term. Nothing was
#     watching for that either, so a recipe could sit in drafts forever after the fact that parked it
#     had gone stale.
#
# This script answers three questions and changes nothing:
#   -Live       which PUBLISHED recipes have an uncarried line right now (should always be zero)
#   -Revivable  which DRAFTED recipes are now unblocked, because the bid that parked them resolved
#   -Thin       which bids ride on a single store, and what they would take down with them
# Default runs all three. Read-only by design: reviving a recipe and taking one down are both Brad's
# calls, and a watch that acts on its own findings is a watch nobody can trust with a wrong one.

param([switch]$Live, [switch]$Revivable, [switch]$Thin, [switch]$Json, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $root
$mp   = Join-Path $repo 'meal-prep'
. (Join-Path $repo 'lib\carriage-lib.ps1')
$guardContract = Join-Path $repo 'lib\guard-contract.ps1'
if (Test-Path $guardContract) { . $guardContract }

# ---------------------------------------------------------------------------------------------------
# PURE CORES. Everything testable takes its inputs as parameters; the live run below reads the files.
# ---------------------------------------------------------------------------------------------------

# A bid is THIN when exactly one store prices it. Not a failure - achiote-paste has been a one-store bid
# on the live board for months and the recipes are fine. It is the early warning: the list of things one
# delisting would break, and how much it would break.
function Get-ThinBids {
  param($FeedIngredients, [hashtable]$BidRecipes)
  $out = @()
  foreach ($p in $FeedIngredients.PSObject.Properties) {
    $v = $p.Value
    if (-not ($v.PSObject.Properties.Name -contains 'stores') -or -not $v.stores) { continue }
    $priced = @()
    foreach ($s in $v.stores.PSObject.Properties) { if ([double]$s.Value -gt 0) { $priced += $s.Name } }
    if ($priced.Count -ne 1) { continue }
    $bid = [string]$p.Name
    if (-not $BidRecipes.ContainsKey($bid)) { continue }   # only bids recipes actually use
    $out += [pscustomobject]@{ bid = $bid; store = $priced[0]; recipes = @($BidRecipes[$bid]) }
  }
  return @($out | Sort-Object { -(@($_.recipes).Count) }, bid)
}

# A parked recipe is REVIVABLE when every bid that parked it now reads CARRIED.
function Get-RevivableRecipes {
  param($Ledger, $FeedCarried)
  $bySlug = @{}
  foreach ($k in $Ledger.Keys) {
    $e = $Ledger[$k]
    if (-not ($e.PSObject.Properties.Name -contains 'parked_recipes')) { continue }
    foreach ($s in @($e.parked_recipes)) {
      if (-not $bySlug.ContainsKey($s)) { $bySlug[$s] = @() }
      $bySlug[$s] += $k
    }
  }
  $out = @()
  foreach ($slug in ($bySlug.Keys | Sort-Object)) {
    $blockers = @($bySlug[$slug])
    $still = @()
    foreach ($k in $blockers) {
      $bid  = if ($k -like 'item:*') { $null } else { $k }
      $item = if ($k -like 'item:*') { $k.Substring(5) } else { '' }
      $c = Get-Carriage -Bid $bid -Item $item -FeedCarried $FeedCarried -Ledger $Ledger
      if ($c.verdict -ne 'CARRIED') { $still += $k }
    }
    $out += [pscustomobject]@{ slug = $slug; blockers = $blockers; still_blocked_by = @($still); revivable = (@($still).Count -eq 0) }
  }
  return @($out)
}

if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) { if ($ok) { Write-Output "  ok  $n" } else { Write-Output "  X   $n  ($got)"; $script:__b++ } }
  $script:__b = 0

  $ING = [pscustomobject]@{
    'one-store'  = [pscustomobject]@{ stores = [pscustomobject]@{ 'Walmart' = 1.5; 'Aldi' = 0 } }
    'two-store'  = [pscustomobject]@{ stores = [pscustomobject]@{ 'Walmart' = 1.5; 'Aldi' = 1.2 } }
    'unused-one' = [pscustomobject]@{ stores = [pscustomobject]@{ 'Fareway' = 3.0 } }
  }
  $thinRes = Get-ThinBids -FeedIngredients $ING -BidRecipes @{ 'one-store' = @('a', 'b'); 'two-store' = @('c') }
  T 'a one-store bid in use is thin' (@($thinRes | Where-Object { $_.bid -eq 'one-store' }).Count -eq 1) 'missed'
  T 'CLEAN TWIN  a two-store bid is not thin' (@($thinRes | Where-Object { $_.bid -eq 'two-store' }).Count -eq 0) 'false positive'
  T 'a one-store bid NO recipe uses is not reported' (@($thinRes | Where-Object { $_.bid -eq 'unused-one' }).Count -eq 0) 'noise'
  T 'thin bids carry what they would take down' ((@($thinRes | Where-Object { $_.bid -eq 'one-store' })[0].recipes).Count -eq 2) 'lost the blast radius'

  $led = @{
    'stuck-bid' = [pscustomobject]@{ verdict = 'UNKNOWN'; parked_recipes = @('parked-dish') }
    'freed-bid' = [pscustomobject]@{ verdict = 'UNKNOWN'; parked_recipes = @('freed-dish') }
  }
  $rev = Get-RevivableRecipes -Ledger $led -FeedCarried @{ 'freed-bid' = $true }
  T 'a recipe whose blocker now prices is revivable' ((@($rev | Where-Object { $_.slug -eq 'freed-dish' })[0]).revivable) 'not revivable'
  T 'MUST FIRE  a recipe still blocked is NOT revivable' (-not (@($rev | Where-Object { $_.slug -eq 'parked-dish' })[0]).revivable) 'revived too early'
  T '   and it names what still blocks it' ((@($rev | Where-Object { $_.slug -eq 'parked-dish' })[0]).still_blocked_by -contains 'stuck-bid') 'unnamed'

  # a recipe parked by TWO bids needs BOTH resolved
  $led2 = @{ 'a-bid' = [pscustomobject]@{ verdict='UNKNOWN'; parked_recipes=@('two-blocker-dish') }
             'b-bid' = [pscustomobject]@{ verdict='UNKNOWN'; parked_recipes=@('two-blocker-dish') } }
  $rev2 = Get-RevivableRecipes -Ledger $led2 -FeedCarried @{ 'a-bid' = $true }
  T 'MUST FIRE  one of two blockers resolving does not revive the recipe' (-not $rev2[0].revivable) 'revived on a partial fix'

  Write-Output ("audit-carriage SELF-TEST " + $(if ($script:__b -eq 0) { 'PASS' } else { "FAILED ($($script:__b))" }))
  exit $(if ($script:__b -eq 0) { 0 } else { 1 })
}

# ---------------------------------------------------------------------------------------------------
# LIVE RUN
# ---------------------------------------------------------------------------------------------------
$all = -not ($Live -or $Revivable -or $Thin)
$feed = (Get-Content (Join-Path $root 'out\smp-feed.json') -Raw | ConvertFrom-Json).ingredients
$fc   = Get-FeedCarriedSet $feed
$led  = Import-CarriageLedger (Join-Path $root 'carriage.json')
$costed = Get-Content (Join-Path $mp 'db\costed.json') -Raw | ConvertFrom-Json

$published = @{}
$hashFile = Join-Path $mp 'db\published-hashes.json'
if (Test-Path $hashFile) { foreach ($p in (Get-Content $hashFile -Raw | ConvertFrom-Json).PSObject.Properties) { $published[$p.Name] = $true } }

$bidRecipes = @{}
foreach ($r in $costed) {
  foreach ($l in $r.lines) {
    $b = Get-BidFromBasis ([string]$l.basis)
    if (-not $b) { continue }
    if (-not $bidRecipes.ContainsKey($b)) { $bidRecipes[$b] = @() }
    $bidRecipes[$b] += [string]$r.slug
  }
}

$findings = 0
$report = [ordered]@{}

if ($all -or $Live) {
  $bad = @($costed | Where-Object { $published.ContainsKey([string]$_.slug) -and @($_.uncarried).Count })
  $report['live_uncarried'] = @($bad | ForEach-Object { [pscustomobject]@{ slug = $_.slug; uncarried = @($_.uncarried) } })
  if (-not $Json) {
    Write-Output ("CARRIAGE: {0} published recipe(s) checked" -f @($costed | Where-Object { $published.ContainsKey([string]$_.slug) }).Count)
    if ($bad.Count) {
      foreach ($b in $bad) { Write-Output ("  X {0}  no Omaha store is proven to carry: {1}" -f $b.slug, (@($b.uncarried) -join ', ')) }
      Write-Output ("CARRIAGE: {0} LIVE recipe(s) sell a dish nobody can shop for. These come down." -f $bad.Count)
    } else { Write-Output '  ok  every published recipe is fully carried' }
  }
  $findings += $bad.Count
}

if ($all -or $Revivable) {
  $rev = Get-RevivableRecipes -Ledger $led -FeedCarried $fc
  $report['revivable'] = @($rev | Where-Object { $_.revivable })
  $report['still_parked'] = @($rev | Where-Object { -not $_.revivable })
  if (-not $Json) {
    $ok = @($rev | Where-Object { $_.revivable })
    if ($ok.Count) {
      Write-Output ("CARRIAGE: {0} DRAFTED recipe(s) are now unblocked - the ingredient that parked them is carried again:" -f $ok.Count)
      foreach ($r in $ok) { Write-Output ("  + {0}  (was blocked by {1})" -f $r.slug, (@($r.blockers) -join ', ')) }
      Write-Output '     Reviving is Brad''s call: re-add the spec, recost, rebuild, then publish -AllowCreate.'
    } else {
      foreach ($r in @($rev | Where-Object { -not $_.revivable })) { Write-Output ("  .  {0} still parked by {1}" -f $r.slug, (@($r.still_blocked_by) -join ', ')) }
    }
  }
}

if ($all -or $Thin) {
  $thinRes = Get-ThinBids -FeedIngredients $feed -BidRecipes $bidRecipes
  $report['thin'] = @($thinRes | ForEach-Object { [pscustomobject]@{ bid = $_.bid; store = $_.store; recipe_count = @($_.recipes).Count } })
  if (-not $Json) {
    Write-Output ("CARRIAGE: {0} bid(s) in use ride on a SINGLE store - one delisting each:" -f @($thinRes).Count)
    foreach ($t in $thinRes) { Write-Output ("  ~ {0,-26} {1,-14} {2} recipe(s)" -f $t.bid, $t.store, @($t.recipes).Count) }
  }
}

if ($Json) { $report | ConvertTo-Json -Depth 8; exit 0 }
if (Get-Command Write-GuardComplete -ErrorAction SilentlyContinue) {
  Write-GuardComplete -Name 'CARRIAGE' -Summary ("{0} live uncarried finding(s)" -f $findings)
}
exit $(if ($findings) { 1 } else { 0 })
