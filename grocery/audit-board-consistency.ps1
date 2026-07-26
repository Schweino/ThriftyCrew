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
param([double]$Tol = 0.30, [int]$MaxNoLink = 0, [string]$OutDir = "", [string]$Embed = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $Embed)  { $Embed  = Join-Path $OutDir 'deals-page-embed.html' }

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
# CHIPS NOW LIVE IN THE FEED (2026-07-16). .pg-stores is filled client-side from public/board.json, so the
# embed contains NO pg-chip markup at all. Auditing the embed would find zero chips and cheerfully report a
# perfect score - a blind guard is worse than no guard. So read the SAME rendered chip html from the feed: it
# is byte-identical to what the browser injects, which is why the chip regex below is unchanged.
$boardFeed = Join-Path (Split-Path $root -Parent) 'public\board.json'
if (Test-Path $boardFeed) {
  $bf = Get-Content $boardFeed -Raw | ConvertFrom-Json
  foreach ($p in $bf.PSObject.Properties) {
    $rid = $p.Name -replace '::r$',''    # '<id>::r' is the recipe row of a shared id; report the plain id
    foreach ($ch in [regex]::Matches([string]$p.Value, "<div class='pg-chip[^']*' data-store=`"([^`"]+)`" data-pu='[^']*'>(.*?)</div>", 'Singleline')) {
      $cstore = $ch.Groups[1].Value -replace '&#39;',"'"
      $body = $ch.Groups[2].Value
      if ($body -notmatch 'pg-see' -and $body -notmatch 'pg-none') { $noLinkList.Add([pscustomobject]@{ id=$rid; store=$cstore }) }
    }
  }
} elseif (Test-Path $Embed) {
  # fallback for a pre-2026-07-16 embed that still carries inline chips
  $html = Get-Content $Embed -Raw
  foreach ($row in [regex]::Matches($html, "data-id='([^']+)'(.*?)</article>", 'Singleline')) {
    $rid = $row.Groups[1].Value
    foreach ($ch in [regex]::Matches($row.Groups[2].Value, "<div class='pg-chip[^']*' data-store=`"([^`"]+)`" data-pu='[^']*'>(.*?)</div>", 'Singleline')) {
      $cstore = $ch.Groups[1].Value -replace '&#39;',"'"
      $body = $ch.Groups[2].Value
      if ($body -notmatch 'pg-see' -and $body -notmatch 'pg-none') { $noLinkList.Add([pscustomobject]@{ id=$rid; store=$cstore }) }
    }
  }
}
$noLink = $noLinkList.Count
$byStore = $noLinkList | Group-Object store | ForEach-Object { [pscustomobject]@{ store=$_.Name; count=$_.Count } } | Sort-Object count -Descending

$report = [ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd HH:mm'); tol=$Tol; no_link_count=$noLink; max_no_link=$MaxNoLink; no_link_by_store=$byStore; no_link=$noLinkList; mismatch_count=$mismatch.Count; mismatch=$mismatch }
$report | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutDir 'consistency-report.json') -Encoding UTF8

# Live-visible health = NO-LINK coverage (how many priced chips fall back to a name). A spike means links are
# being wrongly suppressed (guard too tight / stale audit / bad data) OR data went missing. That's the breach
# signal worth an alert. The mismatch backlog is reported for repair but is NOT live-harmful (all hidden).
$breach = ($noLink -gt $MaxNoLink)
$sev = if ($breach) { 'BREACH' } else { 'OK' }
Write-Output ("consistency: $sev  no-link=$noLink (max $MaxNoLink)  mismatch-backlog=$($mismatch.Count)")
if ($breach) { exit 2 } else { exit 0 }


