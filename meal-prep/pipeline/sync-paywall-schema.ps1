<#
  sync-paywall-schema.ps1 - Make every recipe post's paywall structured data agree with the visibility
  Ghost is actually serving it at.

  WHY THIS EXISTS. build-card2 bakes a paywall JSON-LD node into each post's codeinjection_head:

      {"@context":"https://schema.org","@type":"Article","isAccessibleForFree":false,
       "hasPart":{"@type":"WebPageElement","isAccessibleForFree":false,"cssSelector":".gh-content"},
       "mainEntityOfPage":"...","headline":"..."}

  rotate-free-dinners flips Ghost visibility and NOTHING ELSE - "visibility only - content, tags" are
  deliberately preserved - so the baked claim never follows the rotation. On 2026-08-31 all 20 recipes
  in the free rotation were telling Google their content sat behind a paywall while serving it to
  everyone. Those 20 are the entire top of the funnel.

  This is the same bug class, one layer down, as the hub's baked FREE badges (fixed 2026-08-01 by having
  the rotation republish the hub). The fix has the same shape: the rotation calls this after a flip.

  WHICH DIRECTION IS DANGEROUS. Claiming free content is paywalled costs discovery. Claiming paywalled
  content is free is worse - that is the shape of cloaking. So an UNREADABLE or ambiguous state always
  resolves to "leave the paywall claim in place", never to removing it.

    -WhatIf        report what would change, write nothing
    -Slugs a,b,c   limit to these slugs (default: every recipe in recipes-db)

  Exit 0 = in sync (or fixed).  1 = error.
#>
param(
  [switch]$WhatIf,
  [string[]]$Slugs = @()
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Resolve-Path (Join-Path $here '..\..')
. (Join-Path $repo 'lib\ghost-lib.ps1')
$apiUrl = 'https://map-to-success.ghost.io'
$SITE = 'https://www.thriftycrew.com'

# The block, and only the block: a ld+json script whose payload carries isAccessibleForFree. The Recipe
# node in the same field has no such key, so it can never be caught by this.
$PAYWALL_RX = '<script type="application/ld\+json">\s*\{[^\r\n]*"isAccessibleForFree"[^\r\n]*\}\s*</script>\s*'

function New-PaywallBlock([string]$slug, [string]$headline) {
  $o = [ordered]@{ '@context' = 'https://schema.org'; '@type' = 'Article'; isAccessibleForFree = $false
    hasPart = [ordered]@{ '@type' = 'WebPageElement'; isAccessibleForFree = $false; cssSelector = '.gh-content' }
    mainEntityOfPage = ($SITE + '/' + $slug + '/'); headline = $headline
  }
  return ("<script type=`"application/ld+json`">`n" + ($o | ConvertTo-Json -Depth 6 -Compress) + "`n</script>`n")
}

$db = Get-Content (Join-Path $repo 'meal-prep\recipes-db.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$want = @{}
foreach ($r in $db.recipes) { $want[[string]$r.slug] = $true }
if (@($Slugs).Count) { $want = @{}; foreach ($s in $Slugs) { $want[[string]$s] = $true } }

# ---- read every post once, rather than one call per slug --------------------------------------------
$jwt = Get-GhostJWT -Key (Get-GhostKey -Root $repo)
$hdr = @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' }
$live = @{}
$page = 1
while ($true) {
  $u = "$apiUrl/ghost/api/admin/posts/?limit=100&page=$page&fields=id,slug,title,visibility,updated_at,codeinjection_head"
  $res = Invoke-GhostApi -Uri $u -Headers $hdr
  foreach ($p in $res.posts) { if ($want.ContainsKey([string]$p.slug)) { $live[[string]$p.slug] = $p } }
  if (-not $res.meta.pagination.next) { break }
  $page = [int]$res.meta.pagination.next
  if ($page -gt 40) { break }
}
Write-Output ("read {0} of {1} recipe post(s) from Ghost" -f $live.Count, $want.Count)

$toAdd = @(); $toRemove = @(); $ok = 0; $missing = @(); $errors = @()
foreach ($slug in ($want.Keys | Sort-Object)) {
  $p = $live[$slug]
  if (-not $p) { $missing += $slug; continue }
  $ci = [string]$p.codeinjection_head
  $hasClaim = [bool]([regex]::IsMatch($ci, $PAYWALL_RX))
  # Ghost's visibility is the only source of truth here: recipes-db is a mirror, and a mirror that has
  # drifted is exactly the failure this script exists to catch.
  $isFree = ([string]$p.visibility -eq 'public')
  if ($isFree -and $hasClaim) { $toRemove += $slug }
  elseif ((-not $isFree) -and (-not $hasClaim)) { $toAdd += $slug }
  else { $ok++ }
}
Write-Output ("in sync: {0}   need the claim REMOVED (free but marked paywalled): {1}   need it ADDED (paid but unmarked): {2}" -f $ok, @($toRemove).Count, @($toAdd).Count)
foreach ($s in @($toRemove)) { Write-Output ("   remove  {0}" -f $s) }
foreach ($s in @($toAdd) | Select-Object -First 20) { Write-Output ("   add     {0}" -f $s) }
if (@($missing).Count) { Write-Output ("   NOT FOUND on Ghost: " + (@($missing) -join ', ')) }

if ($WhatIf) { Write-Output '-WhatIf: nothing written.'; exit 0 }
if (-not (@($toRemove).Count + @($toAdd).Count)) { Write-Output 'nothing to do.'; exit 0 }

foreach ($slug in (@($toRemove) + @($toAdd))) {
  $p = $live[$slug]
  $ci = [string]$p.codeinjection_head
  $isFree = ([string]$p.visibility -eq 'public')
  $new = if ($isFree) { [regex]::Replace($ci, $PAYWALL_RX, '') } else { $ci + (New-PaywallBlock $slug ([string]$p.title)) }

  # Never write a no-op, and never write a field that lost more than the block itself.
  if ($new -eq $ci) { $errors += ("{0}: regex matched nothing to change" -f $slug); continue }
  if ($isFree -and ($ci.Length - $new.Length) -gt 600) { $errors += ("{0}: removal would drop {1} chars - too much, skipped" -f $slug, ($ci.Length - $new.Length)); continue }
  if ($new -match '"isAccessibleForFree"' -and $isFree) { $errors += ("{0}: claim survived the removal" -f $slug); continue }

  try {
    $jwt2 = Get-GhostJWT -Key (Get-GhostKey -Root $repo)
    $h2 = @{ Authorization = "Ghost $jwt2"; 'Accept-Version' = 'v5.0'; 'Content-Type' = 'application/json' }
    # Ghost's optimistic concurrency: the PUT must carry the post's own updated_at or it 409s.
    $body = (@{ posts = @(@{ id = $p.id; updated_at = $p.updated_at; codeinjection_head = $new }) } | ConvertTo-Json -Depth 6 -Compress)
    Invoke-GhostApi -Method Put -Uri "$apiUrl/ghost/api/admin/posts/$($p.id)/" -Headers $h2 -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null

    # "did not throw" is not "Ghost took it" - re-read, the same way the rotation's flip does.
    $chk = (Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/$($p.id)/?fields=id,visibility,codeinjection_head" -Headers @{ Authorization = "Ghost " + (Get-GhostJWT -Key (Get-GhostKey -Root $repo)); 'Accept-Version' = 'v5.0' }).posts[0]
    $nowHas = [bool]([regex]::IsMatch([string]$chk.codeinjection_head, $PAYWALL_RX))
    $nowFree = ([string]$chk.visibility -eq 'public')
    if ($nowFree -eq $nowHas) { $errors += ("{0}: after the write Ghost still reports free={1} claim={2}" -f $slug, $nowFree, $nowHas); continue }
    Write-Output ("   {0}  {1}" -f $(if ($isFree) { 'removed ' } else { 'added   ' }), $slug)
  } catch {
    $errors += ("{0}: {1}" -f $slug, $_.Exception.Message)
  }
}

if (@($errors).Count) {
  Write-Output ''
  Write-Output ("PAYWALL SCHEMA SYNC INCOMPLETE: {0} post(s) did not settle" -f @($errors).Count)
  foreach ($e in $errors) { Write-Output ('   ' + $e) }
  exit 1
}
Write-Output 'paywall schema in sync with Ghost visibility.'
exit 0
