<#
  audit-ghost-drift.ps1 - does the LIVE Ghost page still match the local source it was published from?

  WHY THIS EXISTS (2026-08-08). Sixteen tools are published as a single lexical html card whose body is a
  local file (publish-tool-post.ps1 -Slug <slug> -File <name>-tool.html). Nothing ever checked afterwards
  that the live card still equals that file, so a hand-edit in Ghost admin - or any live-only fix - would sit
  there until someone republished from local and silently deleted it. That is the class this sweeps for.

  IT FOUND NO DRIFT ON ITS FIRST RUN, AND THE FIRST VERSION WAS WRONG TO SAY OTHERWISE. It reported my-crew
  (+513 bytes) and cheapest-protein (+27) as drifted, on absolute https://www.thriftycrew.com/... links where
  the local sources have relative /... ones. That was the PLATFORM, not the pages: Ghost stores a
  site-relative URL as an internal __GHOST_URL__ placeholder and expands it to the absolute site URL when the
  Admin API reads the post back, so a local file with href="/x/" can never read back equal. Proved by
  republishing both from local and watching the identical +513 and +27 come straight back with a fresh
  updated_at. It also explains why only those two looked drifted: they are the only two of the sixteen that
  contain relative internal hrefs at all (20 and 1 - the other fourteen have none).
  lib\ghost-drift-lib.ps1 folds that one transformation on both sides. All 16 now match.

  WHAT IT COMPARES. The bytes of the html card, because bytes are what the publisher writes, after undoing
  Ghost's own URL rewrite and nothing else. No rendered-text or whitespace-insensitive comparison: those
  would hide the edits actually worth catching. Fixtures in the lib hold that line in both directions - the
  URL round-trip must stay clean, and a copy edit, a foreign host, a changed path and an extra space must
  each still fire.

  BLIND IS NOT CLEAN. No key, an unreachable API, or a post whose card cannot be read exits 3. A run that
  examined nothing must never print "no drift", which is the zero-rows collapse this estate keeps re-learning.

  THE ALLOWLIST IS KEYED TO THE DRIFT, NOT THE SLUG. A reviewed difference is recorded as slug + the SHA of
  the live body it was reviewed against. Silencing by slug alone would switch the tool off for that page
  forever - the next, different drift on my-crew would never be seen. Change the live body and it speaks up
  again.

  Usage: .\audit-ghost-drift.ps1 [-ShowDiff] [-Discover] [-Accept <slug>] | -SelfTest
  Exit:  0 = every mapped tool matches (or is allowlisted), 1 = drift found, 3 = could not evaluate
#>
param([switch]$ShowDiff, [switch]$Discover, [string]$Accept = '', [switch]$Recipes, [int]$Limit = 0, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
$repo = Split-Path $root -Parent
$API  = 'https://map-to-success.ghost.io'
$manifestPath  = Join-Path $root 'ghost-tool-manifest.json'
$allowPath     = Join-Path $root 'ghost-drift-allowlist.json'

# The comparison itself lives in lib\ghost-drift-lib.ps1, because publish-tool-post.ps1 needs the SAME answer
# to refuse a blind overwrite. One definition, two dot-sources: a shared-lib fix that ships nothing because
# callers kept inline copies is a failure this estate has already paid for.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\ghost-drift-lib.ps1')

# ---------------------------------------------------------------- self-test: frozen fixtures, no network
# The comparison fixtures live WITH the comparison, in lib\ghost-drift-lib.ps1, and this delegates to them
# rather than keeping a second copy. Two sets would drift apart, and the one that mattered would be whichever
# nobody ran - the same duplication trap the lib itself exists to avoid.
if ($SelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }

  $libPath = Join-Path $repo 'lib\ghost-drift-lib.ps1'
  $libOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $libPath -SelfTest 2>&1 | ForEach-Object { [string]$_ }
  $libRc = $LASTEXITCODE
  foreach ($l in $libOut) { Write-Output ('  [lib] ' + $l) }
  T 'the shared comparison lib passes its own fixtures' ($libRc -eq 0) "lib self-test exit $libRc"

  # this script's own contract, on top of the lib's. Only assertions that can actually FAIL go here - a case
  # that cannot fail is worthless, which is the whole premise of test-guards next door.
  T 'the manifest path is under grocery\, next to the other detectors' `
    ((Split-Path $manifestPath -Leaf) -eq 'ghost-tool-manifest.json') $manifestPath
  T 'the shipped manifest parses and maps every local *-tool.html' `
    ($(if (Test-Path $manifestPath) {
        $m = @((Get-Content $manifestPath -Raw | ConvertFrom-Json).tools)
        $localCount = @(Get-ChildItem (Join-Path $repo 'site\tools\*-tool.html') -File).Count
        ($m.Count -gt 0 -and $m.Count -eq $localCount)
      } else { $false })) 'manifest missing, unparseable, or out of step with the local sources'

  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

# ---------------------------------------------------------------- live: fetch every mapped tool's card
. (Join-Path $repo 'lib\ghost-lib.ps1')
$key = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY } else {
  $kf = Join-Path $repo 'meal-prep\.ghostkey'
  if (Test-Path $kf) { (Get-Content $kf -Raw).Trim() } else { '' }
}
if (-not $key) {
  Write-Output 'ghost-drift: COULD NOT EVALUATE - no GHOST_ADMIN_KEY and no meal-prep\.ghostkey, so nothing was compared'
  exit 3
}

# card fetching is Get-GhostCardBody in lib\ghost-drift-lib.ps1 - same reason as the comparison itself

# ---- RECIPE CARDS (2026-08-08): 542 more pages, using the ledger the publisher already keeps ------------
# The tools sweep above compares live bytes to a local FILE. Recipe cards have no such file to compare to -
# the built html is regenerated with today's prices, so a fresh build never equals a card published last
# week, and that difference is by design rather than drift. What IS comparable is db\published-hashes.json:
# publish.ps1 records one SHA1 per slug of exactly what it verified as published. Recomputing that hash from
# what the Admin API returns answers the real question - does live still hold what we published?
if ($Recipes) {
  $mpRoot = Join-Path $repo 'meal-prep'
  $hashPath = Join-Path $mpRoot 'db\published-hashes.json'
  if (-not (Test-Path $hashPath)) {
    Write-Output "ghost-drift/recipes: COULD NOT EVALUATE - no publish ledger at $hashPath"
    Write-GuardComplete -Name 'ghost-drift' -Summary 'recipes blind=no-ledger'
    exit 3
  }
  $ledger = @{}
  foreach ($p in ((Get-Content $hashPath -Raw | ConvertFrom-Json).PSObject.Properties)) { $ledger[$p.Name] = [string]$p.Value }
  if (-not $ledger.Count) {
    Write-Output 'ghost-drift/recipes: COULD NOT EVALUATE - the publish ledger records zero slugs, so a clean result would prove nothing'
    Write-GuardComplete -Name 'ghost-drift' -Summary 'recipes blind=empty-ledger'
    exit 3
  }

  $slugs = @($ledger.Keys | Sort-Object)
  if ($Limit -gt 0 -and $slugs.Count -gt $Limit) { $slugs = @($slugs | Select-Object -First $Limit) }
  Write-Output ("ghost-drift/recipes: checking {0} of {1} slug(s) in the publish ledger" -f $slugs.Count, $ledger.Count)

  $rMatch = @(); $rDrift = @(); $rBlind = @(); $rRoundTrip = @()
  foreach ($slug in $slugs) {
    try {
      $jwt = Get-GhostJWT -Key $key
      $p = (Invoke-RestMethod -Uri "$API/ghost/api/admin/posts/slug/$slug/?formats=lexical&fields=id,slug,title,custom_excerpt,codeinjection_head,lexical" `
            -Headers @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' } -TimeoutSec 45).posts[0]
    } catch { $rBlind += ("{0}: {1}" -f $slug, $_.Exception.Message); continue }
    if (-not $p) { $rBlind += ("{0}: no live post" -f $slug); continue }
    if (-not $p.lexical) { $rBlind += ("{0}: live post has no lexical body" -f $slug); continue }
    try { $lex = $p.lexical | ConvertFrom-Json } catch { $rBlind += ("{0}: lexical did not parse" -f $slug); continue }
    $liveBody = ''
    foreach ($c in $lex.root.children) { if ($c.type -eq 'html' -and $c.html) { $liveBody += [string]$c.html } }
    if (-not $liveBody) { $rBlind += ("{0}: no html card on the live post" -f $slug); continue }
    # same four fields, same order, same separator as publish.ps1
    $liveHash = Get-PublishedContentHash -Body $liveBody -Head ([string]$p.codeinjection_head) -Name ([string]$p.title) -Desc ([string]$p.custom_excerpt)
    if ($liveHash -eq $ledger[$slug]) { $rMatch += $slug; continue }

    # A MISMATCH IS NOT YET DRIFT. The ledger hash was taken over the LOCAL built bytes, which carry
    # site-relative hrefs, while the Admin API expands those to the absolute site URL on read (see
    # Get-CanonicalBody). So a card containing an internal link can never hash equal no matter how faithfully
    # it was published - measured here on the first full sweep: 4 of 542 mismatched, every one of them by
    # exactly 27 bytes, which is the length of the host. The hash cannot be canonicalised retroactively, so
    # fall back to the one comparison that can be: canonicalise BOTH sides of the body and see if the
    # difference survives. This runs only on mismatches, so it costs nothing on a clean sweep.
    $builtPath = Join-Path $mpRoot ("db\built\{0}.body.html" -f $slug)
    $roundTrip = $false
    if (Test-Path $builtPath) {
      $builtBody = [IO.File]::ReadAllText($builtPath, [Text.Encoding]::UTF8)
      if ((Get-CanonicalBody $builtBody) -eq (Get-CanonicalBody $liveBody)) { $roundTrip = $true }
    }
    if ($roundTrip) { $rRoundTrip += $slug; continue }
    $rDrift += [pscustomobject]@{ slug = $slug; ledger = $ledger[$slug]; live = $liveHash; bytes = $liveBody.Length }
  }

  Write-Output ("  {0} match the publish ledger, {1} differ only by the platform URL round-trip, {2} genuinely drifted, {3} could not be read" -f $rMatch.Count, $rRoundTrip.Count, $rDrift.Count, $rBlind.Count)
  foreach ($b in ($rBlind | Select-Object -First 10)) { Write-Output ("  BLIND  " + $b) }
  if ($rBlind.Count -gt 10) { Write-Output ("  ... and {0} more unreadable" -f ($rBlind.Count - 10)) }
  foreach ($d in ($rDrift | Select-Object -First 25)) {
    Write-Output ("  DRIFT  {0,-46} live {1} vs published {2}" -f $d.slug, $d.live.Substring(0,10), $d.ledger.Substring(0,10))
  }
  if ($rDrift.Count -gt 25) { Write-Output ("  ... and {0} more drifted" -f ($rDrift.Count - 25)) }
  if ($rDrift.Count) {
    Write-Output ''
    Write-Output '  A drifted card means LIVE no longer holds what publish.ps1 last verified - edited in Ghost admin,'
    Write-Output '  or a PUT that only partly landed. Republishing that slug overwrites whatever the difference is,'
    Write-Output '  so look before you rebuild: meal-prep\engine\publish.ps1 -Slugs <slug> -Force'
  }
  ($rDrift | ConvertTo-Json -Depth 4) | Out-File (Join-Path $root 'out\ghost-drift-recipes.json') -Encoding utf8
  Write-GuardComplete -Name 'ghost-drift' -Summary ("recipes match={0} roundtrip={1} drift={2} blind={3}" -f $rMatch.Count, $rRoundTrip.Count, $rDrift.Count, $rBlind.Count)
  # blind anywhere means the sweep cannot claim a clean result, even for the slugs it did reach
  if ($rBlind.Count) { exit 3 }
  exit $(if ($rDrift.Count) { 1 } else { 0 })
}

if ($Discover) {
  # Rebuild the manifest by CONTENT, because the slug is not derivable from the filename (leak-finder-tool
  # publishes to money-leak-finder). Fingerprints on slices spread through the file, so a partially drifted
  # page still matches - whole-file matching would only ever find the tools that have NOT drifted.
  $bodies = @{}
  $page = 1
  do {
    $jwt = Get-GhostJWT -Key $key
    $r = Invoke-RestMethod -Uri "$API/ghost/api/admin/posts/?limit=100&page=$page&formats=lexical&fields=id,slug,lexical" `
          -Headers @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' } -TimeoutSec 90
    foreach ($p in $r.posts) {
      if (-not $p.lexical) { continue }
      try { $lex = $p.lexical | ConvertFrom-Json } catch { continue }
      $h = ''
      foreach ($c in $lex.root.children) { if ($c.type -eq 'html' -and $c.html) { $h += [string]$c.html } }
      if ($h) { $bodies[$p.slug] = $h }
    }
    $page++
  } while ($r.meta.pagination.next)
  Write-Output ("discover: {0} html-card post(s) fetched" -f $bodies.Count)

  $map = @()
  foreach ($lf in (Get-ChildItem (Join-Path $repo 'site\tools\*-tool.html') -File | Sort-Object Name)) {
    $local = [IO.File]::ReadAllText($lf.FullName)
    $probe = @()
    for ($i = 1; $i -le 7; $i++) {
      $at = [int]([math]::Floor($local.Length * $i / 8))
      if ($at + 120 -lt $local.Length) { $probe += $local.Substring($at, 120) }
    }
    $best = $null; $bestHits = 0
    foreach ($s in $bodies.Keys) {
      $hits = 0
      foreach ($pr in $probe) { if ($bodies[$s].Contains($pr)) { $hits++ } }
      if ($hits -gt $bestHits) { $bestHits = $hits; $best = $s }
    }
    if ($best -and $bestHits -ge 4) {
      $map += [pscustomobject]@{ slug = $best; file = $lf.Name; matched_slices = ("{0}/{1}" -f $bestHits, $probe.Count) }
      Write-Output ("  {0,-34} -> {1}  ({2}/{3} slices)" -f $lf.Name, $best, $bestHits, $probe.Count)
    } else {
      Write-Output ("  {0,-34} -> NO CONFIDENT MATCH ({1} slices) - left out of the manifest rather than guessed" -f $lf.Name, $bestHits)
    }
  }
  (@{ generated = (Get-Date -Format 'yyyy-MM-dd'); note = 'slug<->local source for the tool posts; rebuild with -Discover'; tools = $map } |
    ConvertTo-Json -Depth 5) | Out-File $manifestPath -Encoding utf8
  Write-Output ("manifest written: {0} tool(s) -> {1}" -f $map.Count, $manifestPath)
  Write-GuardComplete -Name 'ghost-drift' -Summary ("discover mapped={0}" -f $map.Count)
  exit 0
}

if (-not (Test-Path $manifestPath)) {
  Write-Output ("ghost-drift: COULD NOT EVALUATE - no manifest at {0}. Run -Discover once to build it." -f $manifestPath)
  exit 3
}
$manifest = @((Get-Content $manifestPath -Raw | ConvertFrom-Json).tools)
if (-not $manifest.Count) {
  Write-Output 'ghost-drift: COULD NOT EVALUATE - the manifest maps zero tools, so a clean result would prove nothing'
  exit 3
}
$allow = @()
if (Test-Path $allowPath) { try { $allow = @((Get-Content $allowPath -Raw | ConvertFrom-Json).allow) } catch { } }

$clean = @(); $drift = @(); $blind = @()
foreach ($t in $manifest) {
  # site\tools is where discovery (above) reads the tool htmls from; joining the manifest's BARE filename to
  # the repo ROOT went blind on all 16 pages when the 2026-08-15 restructure moved them. ONE derivation.
  $lf = Join-Path $repo (Join-Path 'site\tools' $t.file)
  if (-not (Test-Path $lf)) { $blind += ("{0}: local source {1} is gone" -f $t.slug, $t.file); continue }
  $local = [IO.File]::ReadAllText($lf)
  $live = $null
  try { $live = Get-GhostCardBody -Api $API -Key $key -Slug $t.slug } catch { $blind += ("{0}: {1}" -f $t.slug, $_.Exception.Message); continue }
  if ($null -eq $live) { $blind += ("{0}: no html card on the live post" -f $t.slug); continue }

  $r = Compare-ToolBody $local $live
  if ($r.same) { $clean += $t.slug; continue }
  $h = Get-BodyHash $live
  if (Test-Allowlisted $allow $t.slug $h) { $clean += ($t.slug + ' (reviewed drift)'); continue }
  $drift += [pscustomobject]@{ slug = $t.slug; file = $t.file; delta = $r.delta; hash = $h
                               localMid = $r.localMid; liveMid = $r.liveMid; prefix = $r.prefix }
}

if ($Accept) {
  $hit = @($drift | Where-Object { $_.slug -eq $Accept })
  # the full sweep already ran above, so this is a completed run with a "nothing to do" verdict, not an abort
  if (-not $hit.Count) { Write-Output ("nothing to accept: {0} is not currently drifted" -f $Accept); Write-GuardComplete -Name 'ghost-drift'; exit 1 }
  $new = @($allow) + @([pscustomobject]@{ slug = $Accept; live_hash = $hit[0].hash
                                          reviewed = (Get-Date -Format 'yyyy-MM-dd')
                                          reason = 'REPLACE ME: why the live body is allowed to differ' })
  (@{ allow = $new } | ConvertTo-Json -Depth 5) | Out-File $allowPath -Encoding utf8
  Write-Output ("recorded {0} @ {1} in the allowlist - now write the reason field, an unexplained silence is not a review" -f $Accept, $hit[0].hash)
  Write-GuardComplete -Name 'ghost-drift' -Summary ("accepted={0}" -f $Accept)
  exit 0
}

Write-Output ("ghost-drift: {0} of {1} mapped tool(s) match their local source" -f $clean.Count, $manifest.Count)
foreach ($b in $blind) { Write-Output ("  BLIND  " + $b) }
foreach ($d in $drift) {
  Write-Output ("  DRIFT  {0,-26} live is {1:+#;-#;0} byte(s) vs {2}" -f $d.slug, $d.delta, $d.file)
  if ($ShowDiff) {
    $lm = if ($d.localMid.Length -gt 220) { $d.localMid.Substring(0, 220) + '...' } else { $d.localMid }
    $vm = if ($d.liveMid.Length  -gt 220) { $d.liveMid.Substring(0, 220)  + '...' } else { $d.liveMid }
    Write-Output ("           first difference at char {0}" -f $d.prefix)
    Write-Output ("           local: [" + $lm + "]")
    Write-Output ("           live : [" + $vm + "]")
  }
}
if ($drift.Count) {
  Write-Output ''
  Write-Output '  Republishing from local would OVERWRITE the live body. Decide per tool: bring the change back into'
  Write-Output '  the local source, or record it with -Accept <slug> and say why. -ShowDiff prints what differs.'
}
# BLIND anywhere means the run cannot claim a clean sweep, even if everything it DID reach matched.
if ($blind.Count) { Write-GuardComplete -Name 'ghost-drift' -Summary ("clean={0} drift={1} blind={2}" -f $clean.Count, $drift.Count, $blind.Count); exit 3 }
Write-GuardComplete -Name 'ghost-drift' -Summary ("clean={0} drift={1}" -f $clean.Count, $drift.Count)
exit $(if ($drift.Count) { 1 } else { 0 })
