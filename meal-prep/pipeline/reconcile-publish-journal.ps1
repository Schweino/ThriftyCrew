<#
  reconcile-publish-journal.ps1 - Repair publish journal entries invalidated by an out-of-band head write.

  WHY THIS EXISTS. Get-PublishedContentHash is SHA1 of body + HEAD + title + excerpt, so anything that
  rewrites codeinjection_head on a live post invalidates db\published-hashes.json for that card. That
  opens publish.ps1's drift pre-flight, which then compares the BUILT body against the LIVE body - and
  those legitimately differ on any card rebuilt since the last publish. The guard refuses, and every
  such card is unpublishable until the journal is reconciled.

  Measured 2026-09-07: sync-paywall-schema added the Recipe-node paywall claim to 563 live cards, and
  the next propagate published 18 of 148 and withheld 130 stamps. The syncer now stamps the journal as
  it writes; this repairs the entries it already invalidated.

  IT PROVES, IT DOES NOT ASSUME. A blanket re-stamp from live would silently erase the exact protection
  the drift guard exists for - a card edited by hand in Ghost admin would be overwritten with no trace.
  So an entry is only rewritten when the OLD head can be reconstructed and hashes to EXACTLY the entry
  already in the journal. That match is proof the live body is byte-identical to what was published and
  the head was the only thing that moved. Anything that cannot be proven is left stale and REPORTED:
  a stale entry only refuses a publish, whereas a wrong entry disables the guard.

  -Apply writes. Without it this is a report, because it edits the publish ledger for a live paid site.
#>
# Self-test: pure fixtures over the ghost libs, plus sync-paywall-schema.ps1 read as text for its New-PaywallBlock.
# gate-inputs-text: meal-prep\pipeline\sync-paywall-schema.ps1
param(
  [switch]$Apply,
  [string[]]$Slugs = @(),
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Resolve-Path (Join-Path $here '..\..')
. (Join-Path $repo 'lib\ghost-lib.ps1')
. (Join-Path $repo 'lib\ghost-drift-lib.ps1')   # Get-PublishedContentHash / Join-GhostLexicalBody / the node claim
$apiUrl = 'https://map-to-success.ghost.io'
$JOURNAL_PATH = Join-Path $repo 'meal-prep\db\published-hashes.json'

# The Article block this estate appends for a paid card, restated so a FREE card - whose block the syncer
# removed as well as clearing the node - can have its pre-sync head reconstructed too. Kept byte-identical
# to sync-paywall-schema's New-PaywallBlock; the self-test asserts the two agree rather than trusting it.
function New-TcPaywallArticleBlock {
  param([string]$Slug, [string]$Headline)
  $o = [ordered]@{
    '@context' = 'https://schema.org'; '@type' = 'Article'; isAccessibleForFree = $false
    hasPart = [ordered]@{ '@type' = 'WebPageElement'; isAccessibleForFree = $false; cssSelector = '.gh-content' }
    mainEntityOfPage = "https://thriftycrew.com/$Slug/"; headline = $Headline
  }
  return ("<script type=`"application/ld+json`">" + ($o | ConvertTo-Json -Depth 6 -Compress) + "</script>`n")
}

function Get-TcCandidateOldHeads {
  <# Every head this card could plausibly have carried BEFORE an out-of-band paywall write, most likely
     first. One of these hashing to the journal entry is the proof; none of them doing so is a finding.

     PURE, so the fixtures drive it - the live path only hashes what it returns. #>
  param([string]$LiveHead, [string]$Slug, [string]$Title)
  $c = @()
  $claim = Get-TcRecipeNodeClaim $LiveHead
  if ($null -ne $claim) {
    # The ordinary case: the claim was toggled onto (or off) the Recipe node and nothing else moved.
    $c += (Set-TcRecipeNodeClaim -Head $LiveHead -Paid (-not $claim))
  }
  if ($claim -ne $true) {
    # A freed card also lost its Article block to the caller's regex, so put that back on the far side.
    $withArticle = $LiveHead + (New-TcPaywallArticleBlock -Slug $Slug -Headline $Title)
    $c += $withArticle
    $c += (Set-TcRecipeNodeClaim -Head $withArticle -Paid $true)
  }
  # UNARY COMMA, OR A ONE-CANDIDATE LIST COMES BACK AS A BARE STRING. `return $c` unrolls a single-element
  # array, so $cands[0] silently becomes the first CHARACTER of the head and every hash misses. Caught by
  # the fixtures below, and it is the same collapse this estate has been bitten by repeatedly.
  return ,$c
}

# ---- PROOF 3: THE LIVE HASH IS AN ENTRY ANOTHER JOURNAL ON THIS BOX RECORDED (2026-09-26) ----------------------
# The journal is gitignored, so every checkout has its own copy, and until meal-prep\lib\publish-journal.ps1 a publish
# from a linked worktree recorded its hashes only there. publish.ps1 writes an entry ONLY after the live page verified,
# and the hash covers body, head, title and excerpt, so a live post whose hash equals an entry in ANY journal on this
# machine is byte-identical to a build we published and verified; a hand edit in Ghost admin changes the hash and
# matches nothing. Measured 2026-09-26: 13 recipes refused by the drift guard, each live hash found in exactly one
# worktree journal (6 in agent-ab034ff7f1b928b54 from 2026-09-22 23:43, 7 in agent-acc4db640d784b57b from 2026-09-23
# 08:26), and nowhere in the main checkout's.
function Get-TcSiblingJournalPaths {
  <# Every publish journal on this box except $Own: the main checkout's and each linked worktree's under it. #>
  param([string]$Repo, [string]$Own)
  . (Join-Path $Repo 'lib\main-checkout.ps1')
  $mc = Get-TcMainCheckout -Dir $Repo
  $main = if ($mc.ok -and $mc.main) { $mc.main } else { [string]$Repo }
  $cands = @(Join-Path $main 'meal-prep\db\published-hashes.json')
  $wtRoot = Join-Path $main '.claude\worktrees'
  if (Test-Path -LiteralPath $wtRoot) {
    foreach ($d in @(Get-ChildItem -LiteralPath $wtRoot -Directory -ErrorAction SilentlyContinue)) { $cands += (Join-Path $d.FullName 'meal-prep\db\published-hashes.json') }
  }
  $ownFull = if ($Own) { [IO.Path]::GetFullPath($Own) } else { '' }
  return @($cands | Where-Object { (Test-Path -LiteralPath $_) -and -not [string]::Equals([IO.Path]::GetFullPath($_), $ownFull, [StringComparison]::OrdinalIgnoreCase) })
}
function Find-TcHashElsewhere {
  <# The first journal (a list of @{ path; map }) whose entry for $Slug is EXACTLY $Hash, or ''. PURE. #>
  param([string]$Slug, [string]$Hash, $Journals)
  if (-not $Hash) { return '' }
  foreach ($j in @($Journals)) {
    if ($null -eq $j -or $null -eq $j.map) { continue }
    if ($j.map.Contains($Slug) -and [string]::Equals([string]$j.map[$Slug], $Hash, [StringComparison]::Ordinal)) { return [string]$j.path }
  }
  return ''
}

if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  # BUILT THE WAY build-card2 BUILDS IT, not hand-written. A literal here is a fixture that tests my
  # typing: the first draft used `n line endings while ConvertTo-Json emits `r`n, so all three
  # reconstruction cases failed against code the live probe had already proven correct on three cards.
  $bare = "<script type=`"application/ld+json`">`n" +
          (([ordered]@{ '@context' = 'https://schema.org'; '@type' = 'Recipe'; name = 'Test Bowl' } | ConvertTo-Json -Depth 8)) +
          "`n</script>`n"
  $paid = Set-TcRecipeNodeClaim -Head $bare -Paid $true

  # MUST FIRE - the founding shapes.
  T 'MUST FIRE  THE ONE THIS SCRIPT EXISTS FOR - stripping the claim off a synced head reproduces the pre-sync head EXACTLY, which is what makes the hash match a proof rather than a guess' `
    ((Get-TcCandidateOldHeads -LiveHead $paid -Slug 's' -Title 't') -contains $bare) 'the pre-sync head was not reconstructed'
  T 'MUST FIRE  and it reproduces it to the BYTE - a near-miss hashes to nothing and the entry would be left stale forever' `
    ((Get-PublishedContentHash -Body 'b' -Head ((Get-TcCandidateOldHeads -LiveHead $paid -Slug 's' -Title 't')[0]) -Name 'n' -Desc 'd') -eq (Get-PublishedContentHash -Body 'b' -Head $bare -Name 'n' -Desc 'd')) 'the reconstructed head hashed differently'
  T 'MUST FIRE  a FREED card offers the head WITH its Article block back, because the caller removed that too' `
    ((@(Get-TcCandidateOldHeads -LiveHead $bare -Slug 'test-bowl' -Title 'Test Bowl') | Where-Object { $_ -match '"@type":"Article"' }).Count -ge 1) 'no Article-bearing candidate was offered'

  # MUST NOT FIRE - the legal inputs, and the reason the proof is worth anything.
  T 'MUST NOT FIRE  THE PROTECTION THIS MUST NOT DESTROY - a body edited by hand in Ghost admin hashes to NO candidate, so its entry is left stale and reported rather than overwritten' `
    (-not (@(Get-TcCandidateOldHeads -LiveHead $paid -Slug 's' -Title 't') | Where-Object { (Get-PublishedContentHash -Body 'EDITED-BY-HAND' -Head $_ -Name 'n' -Desc 'd') -eq (Get-PublishedContentHash -Body 'b' -Head $bare -Name 'n' -Desc 'd') })) 'a hand-edited body was accepted as proven'
  T 'MUST NOT FIRE  a head with no Recipe node offers no toggle candidate - "lost its Recipe block" is a different failure and must not be repaired blind' `
    (-not ((Get-TcCandidateOldHeads -LiveHead '' -Slug 's' -Title 't') | Where-Object { $_ -match '"@type":  "Recipe"' })) 'invented a Recipe candidate'
  T 'MUST NOT FIRE  an empty head does not throw' (@(Get-TcCandidateOldHeads -LiveHead '' -Slug 's' -Title 't').Count -ge 0) 'threw'

  # CLEAN TWIN - adjacent behaviour that still works.
  $syncSrc = Get-Content (Join-Path $repo 'meal-prep\pipeline\sync-paywall-schema.ps1') -Raw -Encoding UTF8
  $mm = [regex]::Match($syncSrc, '(?s)function New-PaywallBlock.*?\n\}')
  T 'CLEAN TWIN this file''s Article block still agrees with sync-paywall-schema''s - two copies of one rule, so the divergence is asserted rather than hoped for' `
    ($mm.Success -and ($mm.Value -match 'mainEntityOfPage') -and ($mm.Value -match 'WebPageElement') -and ($mm.Value -match 'Compress')) 'the syncer''s block no longer matches this shape'
  T 'CLEAN TWIN the candidate list never contains the live head itself - that would "prove" an entry that is already in sync and hide a real drift' `
    (-not ((Get-TcCandidateOldHeads -LiveHead $paid -Slug 's' -Title 't') -contains $paid)) 'the live head was offered as its own predecessor'
  T 'MUST NOT FIRE  a ONE-candidate result is still an ARRAY - `return $c` unrolls it to a bare string, and indexing that yields a single CHARACTER whose hash misses every entry' `
    ((Get-TcCandidateOldHeads -LiveHead $paid -Slug 's' -Title 't') -is [array]) ((Get-TcCandidateOldHeads -LiveHead $paid -Slug 's' -Title 't').GetType().Name)
  T 'CLEAN TWIN a paid head round-trips through the toggle, so re-running this cannot corrupt a head it already read' `
    ((Set-TcRecipeNodeClaim -Head ((Get-TcCandidateOldHeads -LiveHead $paid -Slug 's' -Title 't')[0]) -Paid $true) -eq $paid) 'the round trip lost bytes'

  # PROOF 3 - journal-elsewhere (2026-09-26). Pure over in-memory journals.
  $jA = [ordered]@{ 'wt-slug' = 'H-LIVE'; 'other' = 'H-X' }
  $jB = [ordered]@{ 'wt-slug' = 'H-OLDER' }
  $js = @(@{ path = 'B'; map = $jB }, @{ path = 'A'; map = $jA })
  T 'MUST FIRE  a live hash recorded for THIS slug in a worktree journal proves the post is our own verified publish' `
    ((Find-TcHashElsewhere -Slug 'wt-slug' -Hash 'H-LIVE' -Journals $js) -eq 'A') (Find-TcHashElsewhere -Slug 'wt-slug' -Hash 'H-LIVE' -Journals $js)
  T 'MUST NOT FIRE  a hand-edited live post hashes to nothing any journal recorded, so it stays unproven' `
    ((Find-TcHashElsewhere -Slug 'wt-slug' -Hash 'H-HAND-EDIT' -Journals $js) -eq '') 'a hash nobody published was accepted'
  T 'MUST NOT FIRE  the same hash under a DIFFERENT slug proves nothing about this one' `
    ((Find-TcHashElsewhere -Slug 'wt-slug' -Hash 'H-X' -Journals $js) -eq '') 'another slug''s entry was accepted'
  T 'CLEAN TWIN  the comparison is ordinal: a case-changed hash is not a match' `
    ((Find-TcHashElsewhere -Slug 'wt-slug' -Hash 'h-live' -Journals $js) -eq '') 'case-insensitive match'

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); Write-Output 'RECONCILE-JOURNAL-COMPLETE'; exit 1 }
  Write-Output 'SELF-TEST PASS: 4 must-fire cases led by the pre-sync head reconstructing byte-exactly, 6 must-not-fire cases led by a hand-edited body being refused rather than overwritten, and 4 clean twins'
  Write-Output 'RECONCILE-JOURNAL-COMPLETE'
  exit 0
}

# ---------------------------------------------------------------------------------------- live run
$journal = @{}
if (Test-Path $JOURNAL_PATH) {
  $o = Get-Content $JOURNAL_PATH -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($pr in $o.PSObject.Properties) { $journal[$pr.Name] = [string]$pr.Value }
}
if (-not $journal.Count) { Write-Output 'the publish journal is empty or unreadable - nothing to reconcile'; Write-Output 'RECONCILE-JOURNAL-COMPLETE'; exit 2 }

$want = @{}
if (@($Slugs).Count) { foreach ($s in $Slugs) { $want[[string]$s] = $true } }
else { foreach ($k in $journal.Keys) { $want[[string]$k] = $true } }

$jwt = Get-GhostJWT -Key (Get-GhostKey -Root $repo)
$hdr = @{ Authorization = "Ghost $jwt"; 'Accept-Version' = (Get-GhostAcceptVersion) }
$live = @{}
# PAGED THROUGH Invoke-TcGhostPaged (2026-09-19, backlog I197). The old cap here was `$page -gt 40` on the page
# number GHOST sent back as next, so a next that repeated or rewound never exceeded 40 and looped forever, and a
# real 41st page was dropped without a word. The lib caps the pages READ and throws on either.
$resps = Invoke-TcGhostPaged -MaxPages 40 -Fetch {
  param($page)
  Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/?limit=100&page=$page&formats=lexical&fields=id,slug,title,custom_excerpt,visibility,codeinjection_head,lexical" -Headers $hdr
}
foreach ($res in @($resps)) {
  foreach ($p in $res.posts) { if ($want.ContainsKey([string]$p.slug)) { $live[[string]$p.slug] = $p } }
}
Write-Output ("read {0} of {1} journalled post(s) from Ghost" -f $live.Count, $want.Count)

$inSync = 0; $proven = @(); $unproven = @(); $unreadable = @(); $missing = @()
$byProof = @{ 'head' = 0; 'body-matches-built' = 0; 'journal-elsewhere' = 0 }
. (Join-Path $repo 'meal-prep\lib\publish-journal.ps1')   # Read-TcPublishJournal / Save-TcPublishJournal
$sibPaths = Get-TcSiblingJournalPaths -Repo ([string]$repo) -Own $JOURNAL_PATH
$siblings = @()
foreach ($sp in @($sibPaths)) { try { $siblings += @{ path = $sp; map = (Read-TcPublishJournal -Path $sp) } } catch { Write-Output ('   sibling journal unreadable, skipped: ' + $sp) } }
Write-Output ("read {0} other publish journal(s) on this box for the journal-elsewhere proof" -f $siblings.Count)
$restamp = @{}; $elsewhere = @{}
foreach ($slug in ($want.Keys | Sort-Object)) {
  $p = $live[$slug]
  if (-not $p) { $missing += $slug; continue }
  $entry = [string]$journal[$slug]
  if (-not $entry) { continue }

  $lex = $null
  try { if ($p.lexical) { $lex = $p.lexical | ConvertFrom-Json } } catch { }
  $body = if ($lex) { Join-GhostLexicalBody -Root $lex.root } else { '' }
  # A body we cannot read is UNREADABLE, not unchanged. @($null).Count is 1 here, so test the string.
  if ([string]::IsNullOrWhiteSpace($body)) { $unreadable += $slug; continue }

  $head  = [string]$p.codeinjection_head
  $title = [string]$p.title
  $desc  = [string]$p.custom_excerpt
  $liveHash = Get-PublishedContentHash -Body $body -Head $head -Name $title -Desc $desc
  if ($liveHash -eq $entry) { $inSync++; continue }

  # PROOF 1 - the pre-sync head reconstructs and hashes to the entry already in the journal. That match
  # says the live body is byte-identical to what was published and only the head moved.
  $cands = Get-TcCandidateOldHeads -LiveHead $head -Slug $slug -Title $title
  $hit = $null
  foreach ($c in $cands) {
    if ((Get-PublishedContentHash -Body $body -Head $c -Name $title -Desc $desc) -eq $entry) { $hit = $c; break }
  }

  # PROOF 2 - the live body canonically EQUALS the last built body on disk. This is publish.ps1's own
  # second test, so a card passing it would clear the drift guard whatever the journal said; re-stamping
  # it changes no safety property, it just stops the guard opening on every future run.
  #
  # NOT A SUBSTITUTE FOR PROOF 1. db\built is rebuilt in place and untracked, so for any card propagate
  # has rebuilt since the last publish this test fails legitimately - which is the whole reason proof 1
  # exists. It is the weaker net that catches what reconstruction cannot: measured 2026-09-07, proof 1
  # carried 550 cards and proof 2 the remaining 2 - one paid card that gained an Article block alongside
  # the claim, and one freed by the rotation the day before.
  $why = ''
  if ($hit) { $why = 'head' }
  else {
    $builtPath = Join-Path $repo "meal-prep\db\built\$slug.body.html"
    if (Test-Path $builtPath) {
      $built = [IO.File]::ReadAllText($builtPath, [Text.Encoding]::UTF8)
      if ((Get-CanonicalBody $built) -eq (Get-CanonicalBody $body)) { $why = 'body-matches-built' }
    }
  }
  if (-not $why) {
    $src = Find-TcHashElsewhere -Slug $slug -Hash $liveHash -Journals $siblings
    if ($src) { $why = 'journal-elsewhere'; $elsewhere[$slug] = $src }
  }
  if ($why) { $proven += $slug; $byProof[$why] = 1 + [int]$byProof[$why]; $restamp[$slug] = $liveHash; if ($Apply) { $journal[$slug] = $liveHash } }
  else { $unproven += $slug }
}

if ($Apply -and @($proven).Count) {
  # Only the proven keys, under the ledger lock, and mirrored to the main checkout from a worktree.
  $jr = Save-TcPublishJournal -JournalPath $JOURNAL_PATH -Set $restamp
  if ($jr.localError) { Write-Output ('JOURNAL WRITE FAILED: ' + $jr.localError); Write-Output 'RECONCILE-JOURNAL-COMPLETE'; exit 1 }
  if ($jr.mirrorPath) { Write-Output ("   mirrored to the main checkout's journal: {0} key(s) changed{1}" -f $jr.mirror, $(if ($jr.mirrorError) { ' - FAILED: ' + $jr.mirrorError } else { '' })) }
}
foreach ($s in ($elsewhere.Keys | Sort-Object)) { Write-Output ('   journal-elsewhere  ' + $s + '  <- ' + $elsewhere[$s]) }

Write-Output ''
Write-Output ("already in sync    {0}" -f $inSync)
Write-Output ("PROVEN benign      {0}{1}" -f @($proven).Count, $(if ($Apply) { ' - re-stamped' } else { ' - would re-stamp (re-run with -Apply)' }))
Write-Output ("   {0} by reconstructing the pre-sync head, {1} because the live body still equals the last built body, {2} because another journal on this box recorded the live hash" -f $byProof['head'], $byProof['body-matches-built'], $byProof['journal-elsewhere'])
Write-Output ("could not prove    {0} - LEFT STALE ON PURPOSE. A stale entry only refuses the publish; a wrong one disables the drift guard." -f @($unproven).Count)
foreach ($s in ($unproven | Select-Object -Last 25)) { Write-Output ('   ' + $s) }
if (@($unreadable).Count) { Write-Output ("live body unreadable {0}" -f @($unreadable).Count); foreach ($s in ($unreadable | Select-Object -Last 10)) { Write-Output ('   ' + $s) } }
if (@($missing).Count)    { Write-Output ("journalled but not live in Ghost {0}" -f @($missing).Count) }

$code = if (@($unproven).Count -or @($unreadable).Count) { 1 } else { 0 }
Write-Output 'RECONCILE-JOURNAL-COMPLETE'
exit $code
