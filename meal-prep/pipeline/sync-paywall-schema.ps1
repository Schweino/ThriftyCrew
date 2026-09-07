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
. (Join-Path $repo 'lib\ghost-drift-lib.ps1')   # Get-PublishedContentHash / Join-GhostLexicalBody

# ---- THE PUBLISH JOURNAL (2026-09-07) --------------------------------------------------------------
# This script changes PUBLISHED CONTENT, so it owes the journal an entry. Get-PublishedContentHash is
# body + HEAD + title + excerpt, so rewriting a head out of band makes every live hash differ from
# db\published-hashes.json - which opens publish.ps1's drift pre-flight and then refuses the publish,
# because the built body has legitimately moved on since. Measured: a 563-card sync on 2026-09-07 left
# propagate publishing 18 of 148 and withholding 130 stamps.
$JOURNAL_PATH = Join-Path $repo 'meal-prep\db\published-hashes.json'

function Read-TcJournal {
  param([string]$Path)
  $h = @{}
  if (Test-Path $Path) {
    $o = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($pr in $o.PSObject.Properties) { $h[$pr.Name] = [string]$pr.Value }
  }
  return $h
}

function Update-TcJournalEntry {
  <# Records $Hash as what is now published for $Slug. Returns $true only when it actually changed
     something, so the caller can count real writes rather than attempts.

     AN ABSENT SLUG IS LEFT ABSENT. No entry means "never published", and publish.ps1 skips its drift
     pre-flight entirely on those; adding one would ARM a guard that was deliberately off. #>
  param([hashtable]$Journal, [string]$Slug, [string]$Hash)
  if ($null -eq $Journal) { return $false }
  if ([string]::IsNullOrWhiteSpace($Slug) -or [string]::IsNullOrWhiteSpace($Hash)) { return $false }
  if (-not $Journal.ContainsKey($Slug)) { return $false }
  if ($Journal[$Slug] -eq $Hash) { return $false }
  $Journal[$Slug] = $Hash
  return $true
}

$apiUrl = 'https://map-to-success.ghost.io'
$SITE = 'https://www.thriftycrew.com'

# The block, and only the block: a ld+json script whose payload carries isAccessibleForFree.
#
# THE RECIPE NODE NOW CARRIES THE SAME KEY (2026-09-07, backlog I44) and this regex still cannot catch
# it, for a reason worth stating rather than assuming: the Article block is written -Compress, so its
# whole payload is ONE line and `\{[^\r\n]*\}` matches it; the Recipe node is pretty-printed across
# many lines and `[^\r\n]*` cannot span them. Set-TcRecipeNodeClaim owns that node, by parsing.
$PAYWALL_RX = '<script type="application/ld\+json">\s*\{[^\r\n]*"isAccessibleForFree"[^\r\n]*\}\s*</script>\s*'

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

  # ---- the publish journal (2026-09-07). The head is IN Get-PublishedContentHash, so a head this
  # script rewrites invalidates the journal entry, and a stale entry refuses the next publish.
  $j = @{ 'already-published' = 'OLDHASH'; 'a-neighbour' = 'KEEPME' }

  T 'MUST FIRE  THE ONE THIS HALF EXISTS FOR - a card whose head we just rewrote gets its journal entry replaced, or publish.ps1 refuses it forever' `
    ((Update-TcJournalEntry -Journal $j -Slug 'already-published' -Hash 'NEWHASH') -and ($j['already-published'] -eq 'NEWHASH')) ([string]$j['already-published'])

  T 'MUST NOT FIRE  a slug that is NOT in the journal stays out of it - no entry means never published, and publish.ps1 skips its drift pre-flight on those, so adding one ARMS a guard that was deliberately off' `
    ((-not (Update-TcJournalEntry -Journal $j -Slug 'never-published' -Hash 'NEWHASH')) -and (-not $j.ContainsKey('never-published'))) 'an unpublished slug was added to the journal'
  T 'MUST NOT FIRE  an empty hash is refused - a live body that could not be read must leave the entry stale, because a wrong entry DISABLES the drift guard and a stale one only refuses the publish' `
    ((-not (Update-TcJournalEntry -Journal $j -Slug 'already-published' -Hash '')) -and ($j['already-published'] -eq 'NEWHASH')) ([string]$j['already-published'])
  T 'MUST NOT FIRE  a null journal does not throw' `
    ((Update-TcJournalEntry -Journal $null -Slug 'already-published' -Hash 'X') -eq $false) 'threw or claimed a write'

  T 'CLEAN TWIN every other entry survives untouched - this file is the whole publish ledger for 583 cards' `
    (($j['a-neighbour'] -eq 'KEEPME') -and ($j.Count -eq 2)) ([string]$j.Count)
  T 'CLEAN TWIN re-recording the SAME hash reports no write, so the run tally counts real changes rather than attempts' `
    ((Update-TcJournalEntry -Journal $j -Slug 'already-published' -Hash 'NEWHASH') -eq $false) 'an unchanged entry counted as a write'
  T 'CLEAN TWIN the hash recipe is the one publish.ps1 uses, and it still sees the head - the whole defect was the head being inside it' `
    ((Get-PublishedContentHash -Body 'b' -Head 'h1' -Name 'n' -Desc 'd') -ne (Get-PublishedContentHash -Body 'b' -Head 'h2' -Name 'n' -Desc 'd')) 'the digest ignored the head'

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 5 must-fire cases led by the paid claim landing on the Recipe node and by a rewritten head re-stamping the publish journal, 7 must-not-fire cases including the Article block staying untouched and an unpublished slug staying out of the journal, and 7 clean twins'
  exit 0
}

$journal = Read-TcJournal $JOURNAL_PATH
$journalWrites = 0
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
    $chk = (Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/$($p.id)/?formats=lexical&fields=id,visibility,codeinjection_head,title,custom_excerpt,lexical" -Headers @{ Authorization = "Ghost " + (Get-GhostJWT -Key (Get-GhostKey -Root $repo)); 'Accept-Version' = 'v5.0' }).posts[0]
    $nowHas = [bool]([regex]::IsMatch([string]$chk.codeinjection_head, $PAYWALL_RX))
    $nowFree = ([string]$chk.visibility -eq 'public')
    if ($nowFree -eq $nowHas) { $errors += ("{0}: after the write Ghost still reports free={1} claim={2}" -f $slug, $nowFree, $nowHas); continue }
    # THE JOURNAL, FROM THE POST GHOST ACTUALLY STORES (2026-09-07). Same re-read, no extra request.
    # Skipped rather than guessed if the body cannot be read - a wrong entry here disables the drift
    # guard for that card, which is worse than leaving it stale and having the publish refuse.
    try {
      $chkLex = if ($chk.lexical) { $chk.lexical | ConvertFrom-Json } else { $null }
      $chkBody = if ($chkLex) { Join-GhostLexicalBody -Root $chkLex.root } else { '' }
      if ($chkBody) {
        $liveHash = Get-PublishedContentHash -Body $chkBody -Head ([string]$chk.codeinjection_head) `
                      -Name ([string]$chk.title) -Desc ([string]$chk.custom_excerpt)
        # Per slug, not at the end: a crash mid-run must not lose the entries already earned.
        if (Update-TcJournalEntry -Journal $journal -Slug $slug -Hash $liveHash) {
          $journalWrites++
          ($journal | ConvertTo-Json) | Set-Content $JOURNAL_PATH -Encoding UTF8
        }
      } else {
        $errors += ("{0}: head written, but the live body could not be read so the publish journal is now stale for it" -f $slug)
      }
    } catch {
      $errors += ("{0}: head written, but the publish journal could not be updated ({1})" -f $slug, $_.Exception.Message)
    }
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
Write-Output ("publish journal re-stamped for {0} card(s) whose head changed." -f $journalWrites)
Write-Output 'paywall schema in sync with Ghost visibility.'
exit 0
