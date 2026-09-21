# audit-live-price-contract.ps1 - THE FEED CONTRACT for live recipe prices (2026-09-21).
#
# Brad: "The recipe pages should be fetching the pricing from our database ... If a pricing updates in the DB
# its automatically updated on all recipe pages." A price in a recipe post is a <span data-tc-live-price> that
# names its slug, field and basis; the card script fills it from smp-feed.json. This audit is what stops a
# placeholder SILENTLY FILLING WITH NOTHING: it fails if any placeholder in any built card names something the
# feed does not carry.
#
# PER BUILT CARD, PER PLACEHOLDER:
#   1. slug  = the card's own slug, and the slug resolves in the feed's `recipes`
#   2. field is in the live-price registry (render-tokens.ps1 $TC_LIVE_PRICE_BASIS) and basis is that field's
#   3. field cost_ps, basis feed-everyday-whole-package, is computed by the card from pricing_inputs[bid] for
#      EVERY line in the card's smp-sc-data. So every line must carry a bid and the bid must resolve in
#      pricing_inputs with a priced store cell or a priced `current`. One line short and totalAt() returns
#      null, and every span on the page keeps its fallback. THAT is a finding.
#   BASIS WARNING, counted and named, not failed: a line whose only priced cells are SALE cells. The card's
#   everyday lane then falls back to `inputs.everyday || inputs.current`, which is the sale cell, so the page
#   says "(at everyday cost)" over a sale price. Measured 2026-09-21: 58 of 577 published cards, every one on
#   red-bell-pepper (one Family Fare sale cell). Failing it would black out 58 live prices, against Brad's
#   "a recipe page should ALWAYS be able to be costed"; the basis ruling belongs to Brad (plan residual R4).
#   A card still carrying the pre-2026-09-21 placeholder (no slug, no field) is LEGACY: counted, and a finding
#   only once db\live-price-rollout.json reaches stage "catalogue" - so the contract tightens itself at stage 2.
#
# -LivePosts: THE COMPLETENESS CHECK (stage 2, 2026-09-21). Reads EVERY published recipe post (db\published-hashes.json)
#   from the Ghost Admin API - the html Ghost serves a member, so both halves of the paywall - and FAILS a post that
#   lacks the stand-alone fill (fillLivePrices), still carries the old fill that sat behind `if(!bar) return;` on the
#   site-injected .mts-recipe-stats, or carries a placeholder with no slug, field or as-of stamp. A post the API does
#   not return is a finding too. This is what keeps "every live recipe price fills without the site injection" true
#   after the rollout; it prints live posts on the new fill OF how many are published.
# WHICH FEED: grocery\out\smp-feed.json (what the next deploy ships) by default; -Live reads the deployed URL.
# Exit: 0 clean, 1 findings, 3 could not evaluate. Last line: LIVE-PRICE-CONTRACT-COMPLETE.
# Self-test: powershell -File meal-prep\pipeline\audit-live-price-contract.ps1 -SelfTest
param([string]$Slugs = '', [string]$FeedPath = '', [switch]$Live, [string]$BuiltDir = '', [switch]$LivePosts, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$SelfTestLpc = $SelfTest.IsPresent       # before the dot-source: the gate lib's param block rebinds $SelfTest
$lpcSlugs = $Slugs
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $mp 'lib\price-literal-gate.ps1')     # Get-TcLivePriceSpans, and through it the registry
. (Join-Path $repo 'lib\guard-contract.ps1')

function Get-TcCardLines { param([string]$Html)
  $m = [regex]::Match($Html, '(?s)class="smp-sc-data"[^>]*>(.*?)</script>')
  if (-not $m.Success) { return $null }
  return @(($m.Groups[1].Value | ConvertFrom-Json).ing)
}

# Returns @{ legacy = bool; findings = string[] } for one card against one parsed feed.
function Test-TcLivePriceContract { param([string]$Html, [string]$Slug, $Feed, [bool]$LegacyIsFinding)
  $f = @(); $legacy = $false; $warn = @()
  $spans = Get-TcLivePriceSpans (Remove-TcCode $Html)
  if (-not $spans.Count) { return @{ legacy = $false; warnings = @(); findings = @('no live price placeholder at all - the card shows no price') } }
  $named = @($spans | Where-Object { $_.slug -or $_.field })
  if ($named.Count -lt $spans.Count) {
    $legacy = $true
    if ($LegacyIsFinding) { $f += ('' + ($spans.Count - $named.Count) + ' legacy placeholder(s) with no slug or field, after the rollout reached the catalogue') }
  }
  $fields = @{}
  foreach ($s in $named) {
    if ($s.slug -ne $Slug) { $f += ("placeholder names slug '" + $s.slug + "' on the card for '" + $Slug + "'") }
    if (-not $script:TC_LIVE_PRICE_BASIS.ContainsKey([string]$s.field)) { $f += ("placeholder names field '" + $s.field + "', which is not in the live-price registry") ; continue }
    if ($s.basis -ne $script:TC_LIVE_PRICE_BASIS[$s.field]) { $f += ("placeholder basis '" + $s.basis + "' is not " + $s.field + "'s registered basis") }
    $fields[[string]$s.field] = $true
  }
  if ($named.Count -or $legacy) {
    if (-not ($Feed.recipes -and $Feed.recipes.PSObject.Properties[$Slug])) { $f += ("slug '" + $Slug + "' is not in the feed's recipes") }
    if ($fields.ContainsKey('cost_ps') -or $legacy) {
      if ([int]$Feed.schema -lt 2) { $f += ('feed schema ' + $Feed.schema + ' predates sale flags; the everyday fill refuses it') }
      $lines = Get-TcCardLines $Html
      if ($null -eq $lines) { $f += 'no smp-sc-data block: the card script has nothing to price' }
      else {
        foreach ($it in $lines) {
          $bid = [string]$it.bid
          if (-not $bid) { $f += ("line '" + $it.item + "' carries no bid - the everyday fill cannot price it"); continue }
          $pi = if ($Feed.pricing_inputs) { $Feed.pricing_inputs.PSObject.Properties[$bid] } else { $null }
          if (-not $pi) { $f += ("bid '" + $bid + "' (" + $it.item + ") is not in the feed's pricing_inputs"); continue }
          $cells = @(); if ($pi.Value.stores) { $cells = @($pi.Value.stores.PSObject.Properties | ForEach-Object { $_.Value }) }
          $priced = @($cells | Where-Object { [double]$_.perUnitMicros -gt 0 })
          $cur = $pi.Value.current
          if (-not $priced.Count -and -not ($cur -and [double]$cur.perUnitMicros -gt 0)) { $f += ("bid '" + $bid + "' (" + $it.item + ") has no priced cell and no priced current in the feed - the fill refuses the whole card"); continue }
          $every = @($priced | Where-Object { $_.sale -ne $true })
          if ($priced.Count -and -not $every.Count) { $warn += ("bid '" + $bid + "' (" + $it.item + ") is priced only on SALE; the everyday figure falls back to that sale cell") }
        }
      }
    }
  }
  return @{ legacy = $legacy; warnings = $warn; findings = $f }
}

# THE COMPLETENESS VERDICT for one live post's html. Pure, so the self-test drives it with the real old shape.
$script:OLD_FILL = "forEach(function(live){live.textContent='~$'+(tev/nn2)"
function Test-TcLivePostFill { param([string]$Html, [string]$Slug)
  $f = @()
  if ([string]::IsNullOrEmpty($Html)) { return @('the post has no html at all') }
  if ($Html.IndexOf('function fillLivePrices') -lt 0) { $f += 'no stand-alone fill: fillLivePrices() is missing, so its prices depend on the site-wide injection or never fill' }
  if ($Html.IndexOf($script:OLD_FILL) -ge 0) { $f += 'still carries the OLD fill behind if(!bar) return; on the site-injected .mts-recipe-stats' }
  $spans = Get-TcLivePriceSpans (Remove-TcCode $Html)
  if (-not $spans.Count) { $f += 'no live price placeholder' }
  foreach ($sp in $spans) {
    if ($sp.slug -ne $Slug -or -not $sp.field -or $sp.asof -notmatch '^\d{4}-\d{2}-\d{2}T') { $f += ('a placeholder is not the stamped stand-alone form: ' + $sp.raw); break }
  }
  return ,$f
}

if ($SelfTestLpc) {
  $script:fl = 0; $script:n = 0
  function T($m, $c, $g) { $script:n++; if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + '   got: ' + $g); $script:fl++ } }
  $feed = '{"schema":2,"recipes":{"bowl":{"per_serving":2.1}},"pricing_inputs":{"rice":{"stores":{"Aldi":{"perUnitMicros":90000,"sale":false},"Hy-Vee":{"perUnitMicros":70000,"sale":true}}},"chicken":{"stores":{"Aldi":{"perUnitMicros":290000}}},"cheese":{"stores":{"Aldi":{"perUnitMicros":310000,"sale":true}}}}}' | ConvertFrom-Json
  $data = { param($ing) '<script type="application/json" class="smp-sc-data">{"base":14,"ing":' + $ing + '}</script>' }
  $ok2 = '[{"item":"Rice","bid":"rice"},{"item":"Chicken","bid":"chicken"}]'
  $sp = Format-TcLivePriceSpan -Slug 'bowl' -Value '2.10' -AsOf '2026-09-21T05:22:59'
  $r = Test-TcLivePriceContract -Html ((& $data $ok2) + '<p>' + $sp + '</p>') -Slug 'bowl' -Feed $feed -LegacyIsFinding $true
  T 'MUST NOT FIRE  a stamped placeholder whose every line has a non-sale cell in the feed' ($r.findings.Count -eq 0) ($r.findings -join ' | ')
  $r = Test-TcLivePriceContract -Html ((& $data $ok2) + '<p>' + $sp.Replace('data-tc-field="cost_ps"', 'data-tc-field="cost_true"') + '</p>') -Slug 'bowl' -Feed $feed -LegacyIsFinding $true
  T 'MUST FIRE  a placeholder naming a field the feed does not carry (not in the registry)' ($r.findings.Count -ge 1 -and ($r.findings -join ' ') -match 'registry') ($r.findings -join ' | ')
  $r = Test-TcLivePriceContract -Html ((& $data $ok2) + '<p>' + $sp.Replace('slug="bowl"', 'slug="stew"') + '</p>') -Slug 'bowl' -Feed $feed -LegacyIsFinding $true
  T 'MUST FIRE  a placeholder naming another slug' ($r.findings.Count -ge 1 -and ($r.findings -join ' ') -match "names slug 'stew'") ($r.findings -join ' | ')
  $r = Test-TcLivePriceContract -Html ((& $data $ok2) + '<p>' + $sp.Replace('bowl', 'ghost-bowl') + '</p>') -Slug 'ghost-bowl' -Feed $feed -LegacyIsFinding $true
  T 'MUST FIRE  a slug the feed''s recipes map does not carry' (($r.findings -join ' ') -match 'not in the feed') ($r.findings -join ' | ')
  $r = Test-TcLivePriceContract -Html ((& $data '[{"item":"Rice","bid":"rice"},{"item":"Saffron","bid":"saffron"}]') + $sp) -Slug 'bowl' -Feed $feed -LegacyIsFinding $true
  T 'MUST FIRE  a line whose bid is not in pricing_inputs' (($r.findings -join ' ') -match "saffron") ($r.findings -join ' | ')
  $r = Test-TcLivePriceContract -Html ((& $data '[{"item":"Rice","bid":"rice"},{"item":"Cheese","bid":"cheese"}]') + $sp) -Slug 'bowl' -Feed $feed -LegacyIsFinding $true
  T 'MUST NOT FIRE  a line priced ONLY on sale still fills (the script falls back to current), so it is not a finding' ($r.findings.Count -eq 0) ($r.findings -join ' | ')
  T 'MUST FIRE  ...but it IS named as a basis warning: "at everyday cost" over a sale price' (@($r.warnings).Count -eq 1 -and ($r.warnings -join ' ') -match 'SALE') ($r.warnings -join ' | ')
  $feed2 = '{"schema":2,"recipes":{"bowl":{}},"pricing_inputs":{"rice":{"stores":{"Aldi":{"perUnitMicros":90000}}},"leek":{"stores":{"Aldi":{"perUnitMicros":0}},"current":{"perUnitMicros":0}}}}' | ConvertFrom-Json
  $r = Test-TcLivePriceContract -Html ((& $data '[{"item":"Rice","bid":"rice"},{"item":"Leek","bid":"leek"}]') + $sp) -Slug 'bowl' -Feed $feed2 -LegacyIsFinding $true
  T 'MUST FIRE  a bid present in pricing_inputs with no priced cell and no priced current (fills with nothing)' (($r.findings -join ' ') -match 'no priced cell') ($r.findings -join ' | ')
  $r = Test-TcLivePriceContract -Html ((& $data '[{"item":"Rice","bid":"rice"},{"item":"Salt"}]') + $sp) -Slug 'bowl' -Feed $feed -LegacyIsFinding $true
  T 'MUST FIRE  an unbid line' (($r.findings -join ' ') -match 'no bid') ($r.findings -join ' | ')
  $leg = (& $data $ok2) + '<span data-tc-live-price>current release price loading</span>'
  $r = Test-TcLivePriceContract -Html $leg -Slug 'bowl' -Feed $feed -LegacyIsFinding $false
  T 'MUST NOT FIRE  a legacy placeholder while the rollout is at the canary (counted, not failed)' ($r.legacy -and $r.findings.Count -eq 0) ($r.findings -join ' | ')
  $r = Test-TcLivePriceContract -Html $leg -Slug 'bowl' -Feed $feed -LegacyIsFinding $true
  T 'MUST FIRE  the same legacy placeholder once the rollout reaches the catalogue' ($r.findings.Count -eq 1) ($r.findings -join ' | ')
  $r = Test-TcLivePriceContract -Html ((& $data $ok2) + '<p>no price here</p>') -Slug 'bowl' -Feed $feed -LegacyIsFinding $true
  T 'MUST FIRE  a card with no placeholder at all shows no price' ($r.findings.Count -eq 1) ($r.findings -join ' | ')
  # ---- THE COMPLETENESS CHECK (-LivePosts) ----
  $newSp = Format-TcLivePriceSpan -Slug 'bowl' -Value '2.10' -AsOf '2026-09-21T05:22:59'
  $newPost = '<script>function fillLivePrices(){ /* ... */ }</script><p>' + $newSp + '</p>'
  $r = Test-TcLivePostFill -Html $newPost -Slug 'bowl'
  T 'MUST NOT FIRE  a live post with fillLivePrices and a stamped placeholder' ($r.Count -eq 0) ($r -join ' | ')
  $oldPost = '<script>if(stat&&tev!==null){ stat.innerHTML=x; [].slice.call(document.querySelectorAll(''[data-tc-live-price]''))' + '.' + $script:OLD_FILL.Substring(0) + '.toFixed(2);}); }</script><p><span data-tc-live-price>current price loading</span></p>'
  $r = Test-TcLivePostFill -Html $oldPost -Slug 'bowl'
  T 'MUST FIRE  a live post still on the OLD injection-dependent fill (the pre-2026-09-21 card, verbatim shape)' ($r.Count -ge 2 -and ($r -join ' ') -match 'OLD fill' -and ($r -join ' ') -match 'no stand-alone fill') ($r -join ' | ')
  $r = Test-TcLivePostFill -Html ('<script>function fillLivePrices(){}</script><p><span data-tc-live-price>current price loading</span></p>') -Slug 'bowl'
  T 'MUST FIRE  the new fill beside a legacy placeholder (a half-migrated post)' ($r.Count -eq 1 -and $r[0] -match 'stamped') ($r -join ' | ')
  $r = Test-TcLivePostFill -Html '' -Slug 'bowl'
  T 'MUST FIRE  a post with no html' ($r.Count -eq 1) ($r -join ' | ')
  T 'CLEAN TWIN  the registry still carries cost_ps on its basis' ($script:TC_LIVE_PRICE_BASIS['cost_ps'] -eq 'feed-everyday-whole-package') $script:TC_LIVE_PRICE_BASIS['cost_ps']
  if ($script:fl -eq 0) { Write-Output ("audit-live-price-contract self-test PASS ($script:n cases)"); exit 0 } else { Write-Output ("audit-live-price-contract self-test FAIL ($script:fl of $script:n)"); exit 1 }
}

# ---------------- the completeness check over LIVE posts ----------------
if ($LivePosts) {
  . (Join-Path $repo 'lib\ghost-lib.ps1')
  try { $pubL = Get-Content (Join-Path $mp 'db\published-hashes.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Output 'LIVE-PRICE-COMPLETENESS: BLIND - db\published-hashes.json unreadable'; Exit-Guard -Name 'live-price-completeness' -Summary 'posts=0 blind=published' -Code 3 }
  $want = @($pubL.PSObject.Properties.Name | Sort-Object)
  $html = @{}
  try {
    $key = Get-GhostKey
    for ($i = 0; $i -lt $want.Count; $i += 25) {
      $batch = $want[$i..([math]::Min($i + 24, $want.Count - 1))]
      $jwt = Get-GhostJWT -Key $key
      $u = 'https://map-to-success.ghost.io/ghost/api/admin/posts/?filter=' + [uri]::EscapeDataString('slug:[' + ($batch -join ',') + ']') + '&formats=html&fields=slug,html,status&limit=50'
      foreach ($p in (Invoke-GhostApi -Uri $u -Headers @{ Authorization = "Ghost $jwt"; 'Accept-Version' = (Get-GhostAcceptVersion) }).posts) { $html[[string]$p.slug] = [string]$p.html }
    }
  } catch { Write-Output ('LIVE-PRICE-COMPLETENESS: BLIND - the Ghost Admin API could not be read: ' + $_.Exception.Message); Exit-Guard -Name 'live-price-completeness' -Summary ('posts=' + $want.Count + ' blind=ghost') -Code 3 }
  $okN = 0; $bad = 0
  foreach ($s in $want) {
    if (-not $html.ContainsKey($s)) { $bad++; Write-Output ("  $s  published per the journal but the Admin API returned no post"); continue }
    $r = Test-TcLivePostFill -Html $html[$s] -Slug $s
    if ($r.Count) { $bad++; foreach ($x in $r) { Write-Output ("  $s  $x") } } else { $okN++ }
  }
  Write-Output ("live-price-completeness: {0} of {1} published recipe post(s) are on the stand-alone fill with stamped placeholders; {2} are not" -f $okN, $want.Count, $bad)
  Exit-Guard -Name 'live-price-completeness' -Summary ("posts={0} on_new_fill={1} not={2}" -f $want.Count, $okN, $bad) -Code $(if ($bad) { 1 } else { 0 })
}

# ---------------- the audit ----------------
$dir = if ($BuiltDir) { $BuiltDir } else { Join-Path $mp 'db\built' }
try {
  if ($Live) { $feed = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri ('https://feed.thriftycrew.com/smp-feed.json?tcaudit=' + [DateTime]::UtcNow.Ticks)).Content | ConvertFrom-Json; $src = 'deployed feed' }
  else { . (Join-Path $here 'feed-freshness.ps1'); $fp = if ($FeedPath) { $FeedPath } else { $script:FEED_CANONICAL_PATH }; $feed = Get-Content $fp -Raw -Encoding UTF8 | ConvertFrom-Json; $src = $fp }
} catch { Write-Output ('LIVE-PRICE-CONTRACT: BLIND - the feed could not be read: ' + $_.Exception.Message); Exit-Guard -Name 'live-price-contract' -Summary 'cards=0 blind=feed' -Code 3 }
$roll = $null; try { $roll = Get-Content (Join-Path $mp 'db\live-price-rollout.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
$legacyIsFinding = ($roll -and [string]$roll.stage -eq 'catalogue')
$want = @($lpcSlugs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$files = @(Get-ChildItem (Join-Path $dir '*.body.html') -ErrorAction SilentlyContinue)
$scope = 'named'
if ($want.Count) { $files = @($files | Where-Object { $want -contains ($_.Name -replace '\.body\.html$', '') }) }
else {
  # DEFAULT SCOPE = PUBLISHED, read the way feed-covers-published reads it (db\published-hashes.json): a built
  # card nobody published is not a page a reader can open.
  $scope = 'published'
  try { $pub = Get-Content (Join-Path $mp 'db\published-hashes.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Output 'LIVE-PRICE-CONTRACT: BLIND - db\published-hashes.json unreadable'; Exit-Guard -Name 'live-price-contract' -Summary 'cards=0 blind=published' -Code 3 }
  $files = @($files | Where-Object { $pub.PSObject.Properties[($_.Name -replace '\.body\.html$', '')] })
}
if (-not $files.Count) { Write-Output "LIVE-PRICE-CONTRACT: BLIND - no built card resolved under $dir"; Exit-Guard -Name 'live-price-contract' -Summary 'cards=0 blind=no-cards' -Code 3 }
$bad = 0; $legacyN = 0; $nf = 0; $warnN = 0; $warnBids = @{}
foreach ($bf in $files) {
  $slug = $bf.Name -replace '\.body\.html$', ''
  $r = Test-TcLivePriceContract -Html ([IO.File]::ReadAllText($bf.FullName, [Text.Encoding]::UTF8)) -Slug $slug -Feed $feed -LegacyIsFinding $legacyIsFinding
  if ($r.legacy) { $legacyN++ }
  if (@($r.warnings).Count) { $warnN++; foreach ($w in $r.warnings) { $k = [regex]::Match($w, "bid '([^']+)'").Groups[1].Value; $warnBids[$k] = 1 + [int]$warnBids[$k] } }
  if ($r.findings.Count) { $bad++; $nf += $r.findings.Count; foreach ($x in $r.findings) { Write-Output ("  $slug  $x") } }
}
if ($warnN) { Write-Output ("BASIS WARNING: {0} card(s) quote 'at everyday cost' over a SALE-only line: {1}" -f $warnN, (($warnBids.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { $_.Key + ' x' + $_.Value }) -join ', ')) }
Write-Output ("live-price-contract: [{7}] {0} built card(s) against {1} (generated {2}); {3} with findings ({4}); {5} legacy placeholder card(s) ({6})" -f $files.Count, $src, $feed.generated, $bad, $nf, $legacyN, $(if ($legacyIsFinding) { 'a finding: rollout at catalogue' } else { 'counted only: rollout at ' + $(if ($roll) { $roll.stage } else { 'UNREADABLE' }) }), $scope)
Exit-Guard -Name 'live-price-contract' -Summary ("cards={0} with_findings={1} findings={2} legacy={3} basis_warnings={4}" -f $files.Count, $bad, $nf, $legacyN, $warnN) -Code $(if ($bad) { 1 } else { 0 })
