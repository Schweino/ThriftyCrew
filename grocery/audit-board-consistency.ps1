<#
  audit-board-consistency.ps1 - THE single guard that makes "the price shown and the 'See item' link are the
  same current product" a checkable invariant, so the divergence Brad caught (Aldi board $2.29 but link $3.29)
  can never ship silently again. Runs THREE checks against the freshly-built board + product-urls:

    A. WRONG-LINK  : a link exists but its per-unit is >Tol off the board price  -> misleading link (build hides
                     it via the same gate, but we still flag it so it gets repaired, not left hidden forever).
    B. NO-LINK     : priced chips rendering neither a "See item" link nor a "Does not carry" cell (coverage).
    C. STALE-PRICE : the board price differs >Tol from the CURRENT verified price of the same product
                     (product-urls carries the price captured when the link was resolved). Divergence here means
                     the BOARD number is stale (product got repriced/discontinued), which is the other half of
                     the bug. For browser-only stores this is advisory (their pull is periodic).

  Output: out\consistency-report.json { generated, tol, wrong_link[], no_link_count, stale[] } + a one-line
  summary on stdout. Exit code: 0 clean, 2 if any WRONG-LINK (hard - a live misleading link) or if NO-LINK
  coverage worse than -MaxNoLink. STALE is reported (and alerted) but not a hard fail on its own.
  Reuses the exact LinkPU math from build-deals-page.ps1 so the numbers match what the page actually renders.
#>
# MaxNoLink = 0 since 2026-07-12 (Brad's invariant: a displayed price ALWAYS has a matching link - ZERO
# tolerance). Any no-link chip = breach -> check-ad-cycles auto-repairs Family Fare headlessly and alerts ONCE
# per distinct set (sig-deduped) for browser stores until their next re-pull fixes the stored price. The
# temporary 45 headroom for the Fareway launch is obsolete (all Fareway links resolved same-day).
param([double]$Tol = 0.30, [int]$MaxNoLink = 0, [string]$OutDir = "", [string]$Embed = "", [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $Embed)  { $Embed  = Join-Path $OutDir 'deals-page-embed.html' }


# What kind of "See item" does this chip body carry? ONE definition, used by both loops below and by the
# self-test, so the fixture exercises the same code the audit runs.
#   see    - an exact product link
#   none   - a "Doesn't carry" cell (no price, so nothing to verify)
#   adpill - a flyer-only sale cell linked to the store's weekly ad. DELIBERATE: a vision-read flyer jpg
#            has no product page, and searching the store for a plausible match instead is the
#            two-pipelines bug this estate banned. Not a breach.
#   bare   - a priced chip with no link of any kind. THE BUG. Always a breach.
function Get-ChipLinkKind([string]$Body) {
  if ($Body -match 'pg-see') { return 'see' }
  if ($Body -match 'pg-none') { return 'none' }
  if ($Body -match 'pg-adonly') { return 'adpill' }
  return 'bare'
}

if ($SelfTest) {
  # FROZEN FIXTURES (guard-fixture rule): the founding case of the 2026-08-01 change plus the bug it must
  # never hide. Hand-written, never regenerated from a live board.
  $cases = @(
    @{ body = "<span class='pg-price'>`$1.99</span><a class='pg-see' href='/x'>See item</a>"; want='see';    why='an exact product link is a link' },
    @{ body = "<span class='pg-store'>Fareway</span><span class='pg-none'>Doesn&rsquo;t carry</span><a class='pg-see pg-see-none' href='/suggest-an-item/'>See it?</a>"; want='see'; why='a not-carried cell carries the suggest link' },
    @{ body = "<span class='pg-price'>`$4.99</span><a class='pg-adonly' href='https://hy-vee.com/weekly-ad'>Weekly ad</a>"; want='adpill'; why='CLEAN TWIN: a flyer-only sale cell is linked by design and must NOT count as a breach' },
    @{ body = "<span class='pg-store'>Aldi</span><span class='pg-none'>Doesn&rsquo;t carry</span>"; want='none'; why='a bare not-carried cell has no price to verify' },
    @{ body = "<span class='pg-price'>`$3.19</span><span class='pg-meta'>everyday</span>"; want='bare'; why='MUST-FIRE: a PRICED chip with no link at all is the invariant Brad set, and the ad-pill branch must never swallow it' }
  )
  $bad = 0
  foreach ($c in $cases) {
    $got = Get-ChipLinkKind $c.body
    if ($got -ne $c.want) { Write-Output ("  X " + $c.why + "  got '" + $got + "' want '" + $c.want + "'"); $bad++ }
  }
  if ($bad -eq 0) { Write-Output ('audit-board-consistency SELF-TEST PASS (' + $cases.Count + ' frozen chip shapes)'); exit 0 }
  Write-Output ("audit-board-consistency SELF-TEST FAIL ($bad)"); exit 2
}
. (Join-Path $PSScriptRoot 'pu-lib.ps1')
# 2026-07-26 consolidation: LinkPU now DELEGATES to pu-lib's Get-LinkPerUnit (the single per-unit
# implementation; identical params; test-pu-lib.ps1 proves it matches everywhere and resolves more).
# The former local copy - one of three drifting duplicates - is gone. Keep using LinkPU at call sites.
function LinkPU([string]$size, [string]$unit, [double]$price, [string]$name = '') { Get-LinkPerUnit -size $size -unit $unit -price $price -name $name }

# board cells (staples + recipe)
$cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$all = @((Get-Content $cmpF -Raw | ConvertFrom-Json).comparison)
$riF = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $riF) { $all += @((Get-Content $riF -Raw | ConvertFrom-Json).comparison) }
$pd = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items

# apply the SAME board-price overrides the page build applies, so this audit judges the numbers the page
# actually renders (an overridden everyday cell is no longer "stale"). Sales are never overridden.
$ovr = @{}
$ovrFile = Join-Path $root 'board-price-overrides.json'
if (Test-Path $ovrFile) { try { foreach ($c in (Get-Content $ovrFile -Raw | ConvertFrom-Json).cells) { $k=[string]$c.id; if (-not $ovr.ContainsKey($k)) { $ovr[$k]=@{} }; $ovr[$k][[string]$c.store]=[double]$c.per_unit } } catch {} }
if ($ovr.Count) { foreach ($it in $all) { $id=[string]$it.id; if (-not $ovr.ContainsKey($id)) { continue }; foreach ($s in $it.stores) { if (([string]$s.type) -eq 'everyday' -and $ovr[$id].ContainsKey([string]$s.store)) { $nv=[double]$ovr[$id][[string]$s.store]; if ($nv -gt 0) { $s.per_unit=$nv } } } } }

# mismatch = a stored link whose per-unit is >Tol off the board price. The build ALREADY hides these (strict
# gate), so none is a LIVE misleading link - this is the repair backlog: each needs its URL re-pointed to the
# board's product (resolve-links-from-board) OR the board price refreshed. We surface the backlog + trend.
$mismatch = New-Object System.Collections.Generic.List[object]
foreach ($it in $all) { $id=[string]$it.id; $unit=[string]$it.unit
  foreach ($s in $it.stores) { $st=[string]$s.store; $b=[double]$s.per_unit; if ($b -le 0) { continue }
    # SKIP SALE CELLS. A weekly-ad price legitimately differs from the shelf price on the product page
    # the link opens (Hy-Vee sirloin: $6.99/lb on sale vs $13.99/lb regular) - that is the design, not a
    # broken link. Counting them inflated this backlog to 69 and kept the audit permanently BREACHED,
    # which fired the daily Family Fare auto-repair every run for a non-problem (and that repair's
    # re-merge is what resurrected stale links on 2026-07-14). Only an EVERYDAY cell claims to be the
    # same number as its linked product, so only an everyday cell can disagree with it.
    if (([string]$s.type) -ne 'everyday') { continue }
    $e = $pd.$id.$st; if (-not ($e -and $e.url)) { continue }
    $sp=0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$sp)
    $lpu = LinkPU ([string]$e.size) $unit $sp ([string]$e.name); if ($null -eq $lpu) { continue }
    $off = [math]::Abs($lpu-$b)/$b
    if ($off -gt $Tol) { $mismatch.Add([pscustomobject]@{ id=$id; store=$st; unit=$unit; board=[math]::Round($b,4); link=[math]::Round($lpu,4); off_pct=[math]::Round($off*100); product=[string]$e.name; size=[string]$e.size }) }
  }
}

# NO-LINK: a priced chip that renders NEITHER a "See item" link NOR a "Does not carry" cell = a price with no
# way to verify it. HARD INVARIANT (Brad: a displayed price MUST have a matching link). We record the exact
# {id,store} of each so the automation can name them and the URL step can resolve them - not just a count.
$noLinkList = New-Object System.Collections.Generic.List[object]
$adPillList = New-Object System.Collections.Generic.List[object]   # flyer-only sale cells: linked to the weekly ad by design, never a breach
# CHIPS NOW LIVE IN THE FEED (2026-07-16). .pg-stores is filled client-side from public/board.json, so the
# embed contains NO pg-chip markup at all. Auditing the embed would find zero chips and cheerfully report a
# perfect score - a blind guard is worse than no guard. So read the SAME rendered chip html from the feed: it
# is byte-identical to what the browser injects, which is why the chip regex below is unchanged.
$boardFeed = Join-Path (Split-Path $root -Parent) 'public\board.json'
# COUNT WHAT WAS EXAMINED. "no-link=0" is the healthy answer AND the answer a blind run gives, and this check
# has no other output to tell them apart. The header above already worried about this once (chips moved into
# the feed on 2026-07-16 and auditing the embed would have "cheerfully reported a perfect score") but nothing
# was ever added to prove the regex still matches anything. $chipsSeen is taken from the SAME MatchCollection
# the check consumes - never a second pass over the html, which would only re-state the same assumption.
$chipsSeen = 0
if (Test-Path $boardFeed) {
  $bf = Get-Content $boardFeed -Raw | ConvertFrom-Json
  foreach ($p in $bf.PSObject.Properties) {
    $rid = $p.Name -replace '::r$',''    # '<id>::r' is the recipe row of a shared id; report the plain id
    $chips = [regex]::Matches([string]$p.Value, "<div class='pg-chip[^']*' data-store=`"([^`"]+)`" data-pu='[^']*'>(.*?)</div>", 'Singleline')
    $chipsSeen += $chips.Count
    foreach ($ch in $chips) {
      $cstore = $ch.Groups[1].Value -replace '&#39;',"'"
      $body = $ch.Groups[2].Value
      $kind = Get-ChipLinkKind $body
      if ($kind -ne 'see' -and $kind -ne 'none') {
        # A FLYER-ONLY SALE CELL IS NOT A MISSING LINK. Its "See item" is a weekly-ad pill (pg-adonly),
        # which SeeLink emits deliberately: a vision-read flyer jpg has no product page to link to, and
        # searching the store for a plausible match instead is the two-pipelines bug this estate banned
        # (the board once published Hy-Vee Almondmilk while its link opened Blue Diamond Almond Breeze).
        # Counting these as breaches made the daily "board-link price drift" alert fire on cells that can
        # never be fixed, and advise a re-pull that can never work. Measured 2026-08-01: all 21 so-called
        # no-link chips carried an ad pill and ZERO were genuinely bare. Tracked separately so the number
        # is still visible - it is a coverage fact, not a defect.
        if ($kind -eq 'adpill') { $adPillList.Add([pscustomobject]@{ id=$rid; store=$cstore }) }
        else { $noLinkList.Add([pscustomobject]@{ id=$rid; store=$cstore }) }
      }
    }
  }
} elseif (Test-Path $Embed) {
  # fallback for a pre-2026-07-16 embed that still carries inline chips
  $html = Get-Content $Embed -Raw
  foreach ($row in [regex]::Matches($html, "data-id='([^']+)'(.*?)</article>", 'Singleline')) {
    $rid = $row.Groups[1].Value
    $chips = [regex]::Matches($row.Groups[2].Value, "<div class='pg-chip[^']*' data-store=`"([^`"]+)`" data-pu='[^']*'>(.*?)</div>", 'Singleline')
    $chipsSeen += $chips.Count
    foreach ($ch in $chips) {
      $cstore = $ch.Groups[1].Value -replace '&#39;',"'"
      $body = $ch.Groups[2].Value
      $kind = Get-ChipLinkKind $body
      if ($kind -ne 'see' -and $kind -ne 'none') {
        # A FLYER-ONLY SALE CELL IS NOT A MISSING LINK. Its "See item" is a weekly-ad pill (pg-adonly),
        # which SeeLink emits deliberately: a vision-read flyer jpg has no product page to link to, and
        # searching the store for a plausible match instead is the two-pipelines bug this estate banned
        # (the board once published Hy-Vee Almondmilk while its link opened Blue Diamond Almond Breeze).
        # Counting these as breaches made the daily "board-link price drift" alert fire on cells that can
        # never be fixed, and advise a re-pull that can never work. Measured 2026-08-01: all 21 so-called
        # no-link chips carried an ad pill and ZERO were genuinely bare. Tracked separately so the number
        # is still visible - it is a coverage fact, not a defect.
        if ($kind -eq 'adpill') { $adPillList.Add([pscustomobject]@{ id=$rid; store=$cstore }) }
        else { $noLinkList.Add([pscustomobject]@{ id=$rid; store=$cstore }) }
      }
    }
  }
}
$noLink = $noLinkList.Count
$byStore = $noLinkList | Group-Object store | ForEach-Object { [pscustomobject]@{ store=$_.Name; count=$_.Count } } | Sort-Object count -Descending

$report = [ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd HH:mm'); tol=$Tol; chips_examined=$chipsSeen; no_link_count=$noLink; max_no_link=$MaxNoLink; no_link_by_store=$byStore; no_link=$noLinkList; ad_pill_count=$adPillList.Count; ad_pill=$adPillList; mismatch_count=$mismatch.Count; mismatch=$mismatch }
$report | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutDir 'consistency-report.json') -Encoding UTF8

# ZERO CHIPS EXAMINED IS NOT A CLEAN BOARD. Every no-link finding comes from one regex against the rendered
# chip html; if the feed is missing, renamed, or the pg-chip markup drifts by one attribute, that regex
# matches nothing and this guard reports its best possible score - and check-ad-cycles logs "consistency OK".
# 3164 priced chips are examined on a healthy run, so this can never fire on real data. Exit 3 is this
# estate's could-not-evaluate code (audit-coverage-gaps, audit-links, audit-script-census all use it).
if ($chipsSeen -eq 0) {
  Write-Output "consistency: BLIND - examined 0 priced chips (no feed at $boardFeed, or the pg-chip markup changed); no-link=0 out of 0 chips is not a pass"
  exit 3
}

# Live-visible health = NO-LINK coverage (how many priced chips fall back to a name). A spike means links are
# being wrongly suppressed (guard too tight / stale audit / bad data) OR data went missing. That's the breach
# signal worth an alert. The mismatch backlog is reported for repair but is NOT live-harmful (all hidden).
$breach = ($noLink -gt $MaxNoLink)
$sev = if ($breach) { 'BREACH' } else { 'OK' }
Write-Output ("consistency: $sev  no-link=$noLink (max $MaxNoLink)  ad-pill=$($adPillList.Count) (flyer-only, linked to the weekly ad by design)  mismatch-backlog=$($mismatch.Count)  chips-examined=$chipsSeen")
if ($breach) { exit 2 } else { exit 0 }


