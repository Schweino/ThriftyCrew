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
  [string[]]$Slugs = @(),
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Resolve-Path (Join-Path $here '..\..')
. (Join-Path $repo 'lib\ghost-lib.ps1')
$apiUrl = 'https://map-to-success.ghost.io'
$SITE = 'https://www.thriftycrew.com'

# The block, and only the block: a ld+json script whose payload carries isAccessibleForFree.
#
# THE RECIPE NODE NOW CARRIES THE SAME KEY (2026-09-07, backlog I44) and this regex still cannot catch
# it, for a reason worth stating rather than assuming: the Article block is written -Compress, so its
# whole payload is ONE line and `\{[^\r\n]*\}` matches it; the Recipe node is pretty-printed across
# many lines and `[^\r\n]*` cannot span them. Set-TcRecipeNodeClaim owns that node, by parsing.
$PAYWALL_RX = '<script type="application/ld\+json">\s*\{[^\r\n]*"isAccessibleForFree"[^\r\n]*\}\s*</script>\s*'

# ---- THE RECIPE NODE (2026-09-07, backlog I44) ------------------------------------------------------
# The claim now lives on the Recipe node too, because that is the node Google reads for a recipe rich
# result. These three functions are PURE so the fixtures drive them; the live path only composes them.
$LDJSON_RX = '<script type="application/ld\+json">\s*([\s\S]*?)\s*</script>'

function Get-TcRecipeNodeClaim {
  <# $true when the head's Recipe node carries the paywall claim, $false when it does not, and $null
     when the head has no Recipe node at all.

     THREE ANSWERS, NOT TWO. "no Recipe node" is not "not claimed" - a head that lost its Recipe block
     is a different failure and must not read as a tidy negative. #>
  param([string]$Head)
  foreach ($m in [regex]::Matches([string]$Head, $script:LDJSON_RX)) {
    $doc = $null
    try { $doc = $m.Groups[1].Value | ConvertFrom-Json } catch { continue }
    if ($null -eq $doc) { continue }
    if ([string]$doc.'@type' -ne 'Recipe') { continue }
    return [bool]($doc.PSObject.Properties['isAccessibleForFree'] -and ($doc.isAccessibleForFree -eq $false))
  }
  return $null
}

function Set-TcRecipeNodeClaim {
  <# Returns the head with the Recipe node's claim set (Paid) or cleared. Any other ld+json block is
     returned byte-for-byte: this must never touch the Article block, which the caller owns.

     PARSED RATHER THAN REGEXED because hasPart is a nested object, and stripping a nested object out
     of pretty-printed JSON by pattern means balancing braces in text - which is how a head field ends
     up truncated. #>
  param([string]$Head, [bool]$Paid)
  $out = [string]$Head
  foreach ($m in [regex]::Matches([string]$Head, $script:LDJSON_RX)) {
    $payload = $m.Groups[1].Value
    $doc = $null
    try { $doc = $payload | ConvertFrom-Json } catch { continue }
    if ($null -eq $doc -or [string]$doc.'@type' -ne 'Recipe') { continue }
    if ($Paid) {
      if ($doc.PSObject.Properties['isAccessibleForFree']) { $doc.isAccessibleForFree = $false }
      else { $doc | Add-Member -NotePropertyName isAccessibleForFree -NotePropertyValue $false }
      $hp = [pscustomobject]@{ '@type' = 'WebPageElement'; isAccessibleForFree = $false; cssSelector = '.gh-content' }
      if ($doc.PSObject.Properties['hasPart']) { $doc.hasPart = $hp }
      else { $doc | Add-Member -NotePropertyName hasPart -NotePropertyValue $hp }
    } else {
      foreach ($k in @('isAccessibleForFree', 'hasPart')) {
        if ($doc.PSObject.Properties[$k]) { $doc.PSObject.Properties.Remove($k) }
      }
    }
    $new = $doc | ConvertTo-Json -Depth 12
    $out = $out.Replace($m.Value, ("<script type=`"application/ld+json`">`n" + $new + "`n</script>"))
  }
  return $out
}

function New-PaywallBlock([string]$slug, [string]$headline) {
  $o = [ordered]@{ '@context' = 'https://schema.org'; '@type' = 'Article'; isAccessibleForFree = $false
    hasPart = [ordered]@{ '@type' = 'WebPageElement'; isAccessibleForFree = $false; cssSelector = '.gh-content' }
    mainEntityOfPage = ($SITE + '/' + $slug + '/'); headline = $headline
  }
  return ("<script type=`"application/ld+json`">`n" + ($o | ConvertTo-Json -Depth 6 -Compress) + "`n</script>`n")
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  $recipeOnly = "<script type=`"application/ld+json`">`n{`n    `"@context`":  `"https://schema.org`",`n    `"@type`":  `"Recipe`",`n    `"name`":  `"Test Bowl`"`n}`n</script>`n"
  $article    = New-PaywallBlock 'test-bowl' 'Test Bowl'

  # MUST FIRE - the founding shapes.
  T 'MUST FIRE  an unclaimed Recipe node reads as NOT claimed' `
    ((Get-TcRecipeNodeClaim $recipeOnly) -eq $false) ([string](Get-TcRecipeNodeClaim $recipeOnly))
  $paid = Set-TcRecipeNodeClaim -Head $recipeOnly -Paid $true
  T 'MUST FIRE  THE ONE THIS ITEM EXISTS FOR - a paid recipe takes the claim ON THE RECIPE NODE, which is the node Google reads' `
    ((Get-TcRecipeNodeClaim $paid) -eq $true) ([string](Get-TcRecipeNodeClaim $paid))
  T 'MUST FIRE  it takes hasPart too, with the selector Google needs to find the gated section' `
    (($paid -match '"hasPart"') -and ($paid -match '\.gh-content')) 'hasPart or the selector is missing'
  $freed = Set-TcRecipeNodeClaim -Head $paid -Paid $false
  T 'MUST FIRE  THE 2026-08-31 DEFECT, WHICH THIS MUST NOT RECREATE - a freed recipe loses BOTH keys, or it keeps telling Google it is paywalled while serving to everyone' `
    (((Get-TcRecipeNodeClaim $freed) -eq $false) -and ($freed -notmatch '"hasPart"')) ([string](Get-TcRecipeNodeClaim $freed))

  # MUST NOT FIRE - the legal inputs, and the one that keeps the two nodes separate.
  $both = $recipeOnly + $article
  $bothFreed = Set-TcRecipeNodeClaim -Head $both -Paid $false
  T 'MUST NOT FIRE  THE ARTICLE BLOCK IS NOT THIS FUNCTION''S BUSINESS - it survives untouched, because the caller removes it by regex and two owners of one string is how a field gets truncated' `
    ($bothFreed.Contains($article.Trim())) 'the Article block was altered or lost'
  T 'MUST NOT FIRE  the Article regex still cannot reach the Recipe node - it is pretty-printed across lines and the pattern cannot span them' `
    (-not ([regex]::IsMatch((Set-TcRecipeNodeClaim -Head $recipeOnly -Paid $true), $PAYWALL_RX))) 'the regex caught the Recipe node'
  T 'MUST NOT FIRE  a head with NO Recipe node answers $null, not $false - "lost its Recipe block" is a different failure and must not read as a tidy negative' `
    ($null -eq (Get-TcRecipeNodeClaim $article)) ([string](Get-TcRecipeNodeClaim $article))
  T 'MUST NOT FIRE  an empty head does not throw' ($null -eq (Get-TcRecipeNodeClaim '')) 'threw or invented a verdict'

  # CLEAN TWIN - adjacent behaviour that still works.
  T 'CLEAN TWIN the Recipe node keeps its own content across the round trip' `
    (((Set-TcRecipeNodeClaim -Head $recipeOnly -Paid $true) -match '"name"') -and ($freed -match 'Test Bowl')) 'the node lost content'
  T 'CLEAN TWIN setting the claim twice is idempotent, so a re-run cannot double it' `
    (([regex]::Matches((Set-TcRecipeNodeClaim -Head $paid -Paid $true), '"isAccessibleForFree"').Count) -eq 2) `
    ([string][regex]::Matches((Set-TcRecipeNodeClaim -Head $paid -Paid $true), '"isAccessibleForFree"').Count)
  T 'CLEAN TWIN clearing a claim that was never there is a no-op rather than an error' `
    ((Get-TcRecipeNodeClaim (Set-TcRecipeNodeClaim -Head $recipeOnly -Paid $false)) -eq $false) 'clearing an absent claim misbehaved'
  T 'CLEAN TWIN a malformed ld+json block is skipped, not fatal - one bad script tag must not lose the head' `
    ($null -eq (Get-TcRecipeNodeClaim "<script type=`"application/ld+json`">{not json</script>")) 'threw on unparseable json'

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 4 must-fire cases led by the paid claim landing on the Recipe node and the freed one losing it, 4 must-not-fire cases including the Article block staying untouched, and 4 clean twins'
  exit 0
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
$hasArticleBySlug = @{}
foreach ($slug in ($want.Keys | Sort-Object)) {
  $p = $live[$slug]
  if (-not $p) { $missing += $slug; continue }
  $ci = [string]$p.codeinjection_head
  # BOTH NODES, OR THE DECISION IS HALF RIGHT (2026-09-07, backlog I44). A post is only in sync when
  # the Article block AND the Recipe node agree with its visibility; either one alone leaves Google
  # reading a contradiction.
  $hasArticle = [bool]([regex]::IsMatch($ci, $PAYWALL_RX))
  $hasArticleBySlug[$slug] = $hasArticle
  $recipeClaim = Get-TcRecipeNodeClaim $ci        # $true / $false / $null when there is no Recipe node
  $hasClaim = $hasArticle -and ($recipeClaim -ne $false)
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
  # APPEND THE ARTICLE BLOCK ONLY IF IT IS ABSENT (2026-09-07, backlog I44). Since the sync decision
  # now also considers the Recipe node, a PAID card that already carries the Article block but lacks
  # the Recipe claim lands in $toAdd - and the old unconditional append would have written a SECOND
  # Article block to every one of them. That is ~464 live cards with duplicated structured data.
  $new = if ($isFree) { [regex]::Replace($ci, $PAYWALL_RX, '') }
         elseif ($hasArticleBySlug[$slug]) { $ci }
         else { $ci + (New-PaywallBlock $slug ([string]$p.title)) }
  # ...and the Recipe node moves with it (backlog I44).
  $new = Set-TcRecipeNodeClaim -Head $new -Paid (-not $isFree)

  # Never write a no-op, and never write a field that lost more than the block itself.
  if ($new -eq $ci) { $errors += ("{0}: regex matched nothing to change" -f $slug); continue }
  if ($isFree -and ($ci.Length - $new.Length) -gt 600) { $errors += ("{0}: removal would drop {1} chars - too much, skipped" -f $slug, ($ci.Length - $new.Length)); continue }
  # THE GUARD ASKS THE NODES, NOT THE RAW TEXT (2026-09-07, backlog I44). This used to grep the whole
  # field for the string, which was right while only the Article block could carry it. With the claim
  # also on the Recipe node it would fire on EVERY freed recipe and skip the write - a safety check
  # doing precisely the opposite of its job.
  if ($isFree -and ([regex]::IsMatch($new, $PAYWALL_RX) -or ((Get-TcRecipeNodeClaim $new) -eq $true))) {
    $errors += ("{0}: claim survived the removal" -f $slug); continue
  }
  if ((-not $isFree) -and ((Get-TcRecipeNodeClaim $new) -ne $true)) {
    $errors += ("{0}: the Recipe node did not take the claim" -f $slug); continue
  }

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
