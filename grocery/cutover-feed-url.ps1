<#
  cutover-feed-url.ps1 - move the public Worker base URL everywhere, in one command, and prove nothing was missed.

  WHY THIS EXISTS (2026-08-08). The smp-feed Worker's address is a `workers.dev` subdomain, and Cloudflare
  assigns ONE PER ACCOUNT. The estate is consolidating onto the admin@thriftycrew.com Cloudflare account:
  the DOMAIN moved (nameservers went lola/weston -> mario/val and every record survived), but a Worker
  cannot be moved between accounts - it has to be recreated, which mints a NEW subdomain. At that moment
  every reference to the old one points at a Worker that is no longer there.

  THE BLAST RADIUS IS BIGGER THAN THE SOURCE TREE. 14 references live in 11 scripts, but the URL is also
  BAKED INTO 542 built recipe cards and the board page - so a cutover is not just an edit, it is an edit
  plus a rebuild plus a republish. And the failure is QUIET: each recipe card falls back to its baked-in
  baseline cost and the board holds its last published prices, so a missed reference looks fine for weeks.

  WHY A CUTOVER TOOL RATHER THAN A SHARED CONSTANT. Restructuring ten working files to read one variable is
  the textbook answer, and it was the wrong trade here: this value has changed twice in the estate's life,
  the references sit inside JS-in-PowerShell string literals where an interpolation slip fails silently,
  and the change was proposed mid-migration. A rewrite tool plus a drift guard gives the same one-command
  cutover with none of that risk. lib\site-endpoints.ps1 holds the canonical value the guard compares to.

  THE PERMANENT FIX IS A CUSTOM DOMAIN. Put the Worker on feed.thriftycrew.com and the address stops
  depending on which account owns it - pending since 2026-07-08, blocked precisely because the domain and
  the Worker were in different Cloudflare accounts. Consolidation unblocks it. Run this once with that
  domain and the problem never recurs.

  Usage:
    .\cutover-feed-url.ps1                                  audit: report every reference + drift
    .\cutover-feed-url.ps1 -NewBase https://feed.thriftycrew.com -Apply
    .\cutover-feed-url.ps1 -SelfTest
#>
param([string]$NewBase, [switch]$Apply, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\income\grocery' }
$repo = Split-Path $root -Parent

function Get-CanonicalBase { param([string]$RepoRoot)
  $lib = Join-Path $RepoRoot 'lib\site-endpoints.ps1'
  $m = [regex]::Match([IO.File]::ReadAllText($lib), "TC_FEED_BASE\s*=\s*'([^']+)'")
  if (-not $m.Success) { throw 'cutover: could not read TC_FEED_BASE from lib\site-endpoints.ps1' }
  return $m.Groups[1].Value
}
function Test-ValidBase { param([string]$B)
  # an https origin with no trailing slash and no path - callers concatenate a rooted path onto it
  return ($B -match '^https://[a-z0-9][a-z0-9.-]*[a-z0-9]$')
}

if ($SelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }
  T 'CLEAN TWIN a plain https origin is a valid base'      (Test-ValidBase 'https://feed.thriftycrew.com') 'rejected'
  T 'CLEAN TWIN the current workers.dev base is valid'     (Test-ValidBase 'https://smp-feed.ancient-snow-93df.workers.dev') 'rejected'
  T 'MUST FIRE  a trailing slash is refused (double-slash URLs)' (-not (Test-ValidBase 'https://feed.thriftycrew.com/')) 'accepted'
  T 'MUST FIRE  a base carrying a path is refused'         (-not (Test-ValidBase 'https://feed.thriftycrew.com/smp-feed.json')) 'accepted'
  T 'MUST FIRE  http (not https) is refused'               (-not (Test-ValidBase 'http://feed.thriftycrew.com')) 'accepted'
  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

$canonical = Get-CanonicalBase -RepoRoot $repo
# any workers.dev / feed origin that appears in the tree - so a STALE one is visible, not just the current
$rxAny = 'https://(?:smp-feed\.[a-z0-9-]+\.workers\.dev|feed\.thriftycrew\.com)'

# .html IS IN THIS LIST, and leaving it out is the mistake this comment exists to prevent. The first run
# scanned only .ps1/.js/.yml/.json/.md, reported "15 references in 12 files", rewrote them - and the 542
# rebuilt recipe cards came out BYTE-IDENTICAL, still carrying the old URL. The reason: build-card2 reads
# pipeline\tpl2-scaler-prefix.html, an HTML TEMPLATE holding the scaler widget's `var SMPFEED=...`. Widening
# the scan then found the same URL in every member-tool template too (meal plan builder, my-crew, staples,
# payday stretcher, protein leaderboard, price widget, dinner tools, the join interstitial and a
# code-injection head). A cutover that misses those leaves the tools fetching a Worker that is gone.
#
# site-backups\ and archive\ are EXCLUDED ON PURPOSE: they are dated snapshots of what was deployed at a
# past moment. Rewriting a historical record to say something it never said destroys its only value.
$scan = @(Get-ChildItem $repo -Recurse -File -Include *.ps1, *.js, *.yml, *.json, *.md, *.html, *.htm -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -notmatch '\\worktrees\\|node_modules|\\out\\|\\db\\built\\|\\archive\\|\\site-backups\\|cutover-feed-url\.ps1' })

$refs = @()
foreach ($f in $scan) {
  $txt = [IO.File]::ReadAllText($f.FullName)
  foreach ($m in [regex]::Matches($txt, $rxAny)) {
    $refs += [pscustomobject]@{ file = $f.FullName; rel = $f.FullName.Replace($repo + '\', ''); found = $m.Value }
  }
}
$stale = @($refs | Where-Object { $_.found -ne $canonical })

Write-Output ("feed-url: {0} reference(s) across {1} file(s); canonical = {2}" -f $refs.Count, (@($refs | Select-Object -ExpandProperty rel -Unique)).Count, $canonical)
if ($stale.Count) {
  Write-Output ("  ! {0} reference(s) do NOT match the canonical base:" -f $stale.Count)
  $stale | Group-Object found | ForEach-Object { Write-Output ("      {0}  x{1}" -f $_.Name, $_.Count) }
}

if (-not $NewBase) {
  # audit mode also reports the BAKED surfaces, because editing source is only half a cutover
  $built = @(Get-ChildItem (Join-Path $repo 'meal-prep\db\built\*.html') -ErrorAction SilentlyContinue |
             Where-Object { (Select-String -Path $_.FullName -Pattern $rxAny -Quiet) })
  Write-Output ''
  Write-Output ("BAKED into published output (these need a REBUILD + REPUBLISH, not an edit):")
  Write-Output ("    built recipe cards : {0}" -f $built.Count)
  Write-Output ("    board page         : {0}" -f $(if (Test-Path (Join-Path $repo 'grocery\out\deals-page.html')) { @(Select-String -Path (Join-Path $repo 'grocery\out\deals-page.html') -Pattern $rxAny).Count } else { 'not built' }))
  Write-Output ''
  Write-Output 'to cut over:  .\cutover-feed-url.ps1 -NewBase https://feed.thriftycrew.com -Apply'
  exit $(if ($stale.Count) { 1 } else { 0 })
}

if (-not (Test-ValidBase $NewBase)) { throw "cutover: '$NewBase' is not a bare https origin (no trailing slash, no path)" }
Write-Output ''
Write-Output ("CUTOVER {0} -> {1}{2}" -f $canonical, $NewBase, $(if ($Apply) { '' } else { '   (dry run - pass -Apply)' }))

$touched = 0; $changed = 0
foreach ($g in ($refs | Group-Object file)) {
  $txt = [IO.File]::ReadAllText($g.Name)
  $new = [regex]::Replace($txt, $rxAny, $NewBase)
  if ($new -eq $txt) { continue }
  $n = ([regex]::Matches($txt, $rxAny)).Count
  Write-Output ("    {0,-52} {1} ref(s)" -f $g.Group[0].rel, $n)
  $touched++; $changed += $n
  if ($Apply) { [IO.File]::WriteAllText($g.Name, $new) }
}
# the canonical value itself moves last, so a re-run reports clean
if ($Apply) {
  $lib = Join-Path $repo 'lib\site-endpoints.ps1'
  [IO.File]::WriteAllText($lib, ([IO.File]::ReadAllText($lib) -replace [regex]::Escape($canonical), $NewBase))
  Write-Output ("    {0,-52} canonical value" -f 'lib\site-endpoints.ps1')
}
Write-Output ''
Write-Output ("{0} reference(s) in {1} file(s){2}" -f $changed, $touched, $(if ($Apply) { ' REWRITTEN' } else { ' would change' }))
if ($Apply) {
  Write-Output ''
  Write-Output 'NOT DONE YET - the URL is also BAKED into published output. Finish with:'
  Write-Output '    meal-prep\engine\build-cards.ps1                 (rebuild all 542 cards)'
  Write-Output '    meal-prep\engine\publish.ps1 -Slugs <all> -Force (republish them)'
  Write-Output '    grocery\build-deals-page.ps1 + publish-deals-page.ps1'
  Write-Output '    grocery\export-feed.ps1, then commit+push so Cloudflare redeploys'
  Write-Output '  Keep the OLD Worker alive until every surface above is verified on the new URL.'
}
exit 0
