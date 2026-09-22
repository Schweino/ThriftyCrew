# prepare-article-price-edits.ps1 - THE RESOLVER for the site-wide price monitor's findings on articles (2026-09-22,
# Brad's ruling C of 2026-09-21: a typed grocery price in an article goes LIVE where the article names something
# the pipeline actually prices - a board commodity or an engine recipe - and is REMOVED where it does not).
#
# THREE STEPS, each its own switch, none of which writes to Ghost except -Land with -Apply:
#   -Inventory   read each article's CURRENT body (content\ghost-adopted\<slug>.json when it has one, else a read-only
#                Admin API GET), list EVERY dollar figure with its sentence, mark the ones the monitor's literal
#                shape catches, and write content\ghost-adopted\price-edits\inventory.json. Targets: -Slugs, or the
#                non-exempt pages in grocery\out\sitewide-price-literals.json (the monitor's findings file).
#   -Prepare     read content\ghost-adopted\price-edits\<slug>.decisions.json (a person's or a writer's ruling on
#                every figure: find -> replace, where a BACKED figure is a token {{live-recipe:<slug>}} or
#                {{live-unit:<bid>:<per>}} and an UNBACKED one is prose without a figure), render each token through
#                Format-TcLivePriceSpan with a STAMPED fallback on the fill's own basis (a recipe: its built card's
#                stamped span; a commodity: public\tc-live-price.js run in jsdom against the canonical feed), add the
#                one script tag, and write <slug>.edit.json: the exact lexical change against the pinned base. It
#                REFUSES an edit whose result still carries a literal the monitor would count, a find that is not
#                unique, or a title that still states a price.
#   -Land        (the integrator, after the feed keys ship) GET the live post, refuse unless its updated_at is the
#                base's, apply the edit, and with -Apply PUT it. Without -Apply it prints what it would send.
#
# Exit 0 ok, 1 a refused edit (named), 3 could not evaluate. Last line: ARTICLE-PRICE-EDITS-COMPLETE.
[CmdletBinding()]
param([switch]$Inventory, [switch]$Prepare, [switch]$Land, [switch]$Apply, [string]$Slugs = '', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$SelfTestApe = $SelfTest.IsPresent
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $mp 'lib\sitewide-price-lib.ps1')   # the monitor's literal shape + render-tokens' span writer (via the gate)
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $repo 'lib\ghost-lib.ps1')   # read-only GETs for an article with no export; -Land's PUT
$adopted = Join-Path $repo 'content\ghost-adopted'
$editDir = Join-Path $adopted 'price-edits'
$API = 'https://map-to-success.ghost.io'
$SCRIPT_TAG = '<script src="https://feed.thriftycrew.com/tc-live-price.js" defer></script>'
$slugList = @(); if ($Slugs) { $slugList = @($Slugs -split '[,\s]+' | Where-Object { $_ }) }

function Get-ApeHtmlOfLexical { param([string]$Lexical)
  $lx = $Lexical | ConvertFrom-Json
  $kids = @($lx.root.children)
  $types = @($kids | ForEach-Object { [string]$_.type } | Select-Object -Unique)
  if ($kids.Count -ne 1 -or $types[0] -ne 'html') { return $null }   # only the single-html-card shape is edited here
  return [string]$kids[0].html
}
function Set-ApeHtmlOfLexical { param([string]$Lexical, [string]$Html)
  $lx = $Lexical | ConvertFrom-Json
  $lx.root.children[0].html = $Html
  return ($lx | ConvertTo-Json -Depth 30 -Compress)
}
function Get-ApeSha { param([string]$S) $b = [Text.Encoding]::UTF8.GetBytes($S); return (-join ([Security.Cryptography.SHA256]::Create().ComputeHash($b) | ForEach-Object { $_.ToString('x2') })) }
function Get-ApeFigures { param([string]$Html)
  $t = ConvertTo-TcReaderText $Html
  $tight = @(Find-TcGroceryPriceLiterals $t | ForEach-Object { $_.figure })
  $out = @()
  foreach ($m in [regex]::Matches($t, '\$\d[\d,]*(?:\.\d+)?')) {
    $a = [Math]::Max(0, $t.LastIndexOfAny([char[]]'.!?', [Math]::Max(0, $m.Index - 1)) + 1); $b = $t.IndexOfAny([char[]]'.!?', $m.Index + $m.Length)
    if ($b -lt 0 -or $b - $a -gt 400) { $b = [Math]::Min($t.Length, $m.Index + 160) }
    $sent = $t.Substring($a, [Math]::Max(0, $b - $a + 1)).Trim()
    $isTight = @($tight | Where-Object { $_.Contains($m.Value) }).Count -gt 0
    $out += [pscustomobject]@{ figure = $m.Value; sentence = $sent; monitor_shape = $isTight }
  }
  return ,$out
}

# the article's CURRENT base: the adopted export when present, else a read-only Admin API GET (posts, then pages)
function Get-ApeBase { param([string]$Slug)
  $j = Join-Path $adopted ($Slug + '.json')
  if (Test-Path $j) { $o = Read-JsonFile $j; return [pscustomobject]@{ slug = $Slug; id = $o.id; kind = $o.kind; title = $o.title; visibility = $o.visibility; updated_at = $o.updated_at; lexical = [string]$o.lexical; source = 'content/ghost-adopted/' + $Slug + '.json (exported ' + $o.exported_on + ')' } }
  if (-not $script:gkey) { $script:gkey = Get-GhostKey }
  foreach ($res in 'posts', 'pages') {
    try {
      $r = Invoke-GhostApi -Method GET -Uri ("$API/ghost/api/admin/$res/slug/$Slug/?formats=lexical") -Headers @{ Authorization = ('Ghost ' + (Get-GhostJWT -Key $script:gkey)); 'Accept-Version' = (Get-GhostAcceptVersion) } -TimeoutSec 60
      $p = @($r.$res)[0]
      if ($p) { return [pscustomobject]@{ slug = $Slug; id = $p.id; kind = $res.TrimEnd('s'); title = $p.title; visibility = $p.visibility; updated_at = $p.updated_at; lexical = [string]$p.lexical; source = "Admin API GET $res (read-only) " + (Get-Date -Format s) } }
    } catch { }
  }
  return $null
}

# A live span for a decision token, with its fallback STAMPED on the fill's own basis.
function Get-ApeRecipeSpan { param([string]$RecipeSlug)
  $b = Join-Path $mp ('db\built\' + $RecipeSlug + '.body.html')
  if (-not (Test-Path $b)) { throw "recipe '$RecipeSlug' has no built card, so there is no stamped fallback on the fill's basis" }
  $sp = @(Get-TcLivePriceSpans ([IO.File]::ReadAllText($b)) | Where-Object { $_.asof })
  if ($sp.Count -eq 0) { throw "recipe '$RecipeSlug' has no stamped placeholder in its built card" }
  return (Format-TcLivePriceSpan -Slug $RecipeSlug -Field 'cost_ps' -Value $sp[0].fallback -AsOf $sp[0].asof)
}
function Get-ApeUnitValues { param([object[]]$Pairs)   # @(@{bid;per}) -> hashtable 'bid|per' -> '1.99'; runs the SHIPPED fill
  $node = Get-ChildItem 'C:\Codex\tools' -Filter 'node-*-win-x64' -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
  if (-not $node) { throw 'node is missing under C:\Codex\tools: a commodity fallback cannot be stamped by the real fill' }
  $feedPath = Join-Path $repo 'grocery\out\smp-feed.json'
  $feed = Read-JsonFile $feedPath
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('tc-ape-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  try {
    $body = ($Pairs | ForEach-Object { '<p><span data-tc-live-price data-tc-bid="' + $_.bid + '" data-tc-per="' + $_.per + '" data-tc-field="unit_price" data-tc-basis="feed-everyday-per-unit" data-tc-fallback="0.01">~$0.01</span></p>' }) -join ''
    $body += '<script>' + [IO.File]::ReadAllText((Join-Path $repo 'public\tc-live-price.js')) + '</script>'
    [IO.File]::WriteAllText((Join-Path $tmp 'a.html'), $body)
    $job = @{ jsdom = 'C:\Codex\tools\jsdom-env'; feedPath = $feedPath; feedMode = 'ok'; waitMs = 1500; cards = @(@{ slug = 'stamp'; htmlPath = (Join-Path $tmp 'a.html'); kind = 'body' }) }
    [IO.File]::WriteAllText((Join-Path $tmp 'job.json'), ($job | ConvertTo-Json -Depth 5))
    $lines = & (Join-Path $node.FullName 'node.exe') (Join-Path $here 'live-price-fill.js') (Join-Path $tmp 'job.json')
    $res = $null; foreach ($l in @($lines)) { if ($l -match '^\{') { $res = $l | ConvertFrom-Json } }
    $out = @{}; $i = 0
    foreach ($s in @($res.spans)) { $p = $Pairs[$i]; $i++; if ($s.filled) { $out[$p.bid + '|' + $p.per] = [string]$s.filled } }
    return @{ values = $out; asof = [string]$feed.generated }
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($SelfTestApe) {
  $script:fl = 0; $script:n = 0
  function T($m, $c, $g) { $script:n++; if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + '   got: ' + $g); $script:fl++ } }
  $lex = '{"root":{"children":[{"type":"html","version":1,"html":"<p>Rice runs $0.89 a pound, and the 15 year costs you $617 more each month.</p>"}],"direction":null,"format":"","indent":0,"type":"root","version":1}}'
  $h = Get-ApeHtmlOfLexical $lex
  $f = Get-ApeFigures $h
  T 'CLEAN TWIN  the inventory lists EVERY dollar figure, and marks only the grocery one as the monitor''s shape' ($f.Count -eq 2 -and $f[0].monitor_shape -and -not $f[1].monitor_shape) (($f | ForEach-Object { $_.figure + '=' + $_.monitor_shape }) -join ' ')
  $lex2 = Set-ApeHtmlOfLexical $lex '<p>x</p>'
  T 'CLEAN TWIN  a lexical round trip keeps the single html card and changes only its html' ((Get-ApeHtmlOfLexical $lex2) -eq '<p>x</p>') $lex2
  $para = '{"root":{"children":[{"type":"paragraph","children":[]}],"type":"root","version":1}}'
  T 'MUST FIRE  a body that is not one html card is refused, never half-edited' ($null -eq (Get-ApeHtmlOfLexical $para)) ''
  if ($script:fl -eq 0) { Write-Output ("prepare-article-price-edits self-test PASS ($script:n cases)"); exit 0 } else { Write-Output ("prepare-article-price-edits self-test FAIL ($script:fl of $script:n)"); exit 1 }
}

if ($Inventory) {
  if (-not $slugList.Count) {
    $fp = Join-Path $repo 'grocery\out\sitewide-price-literals.json'
    if (-not (Test-Path $fp)) { Write-Output 'no -Slugs and no monitor findings file: run monitor-sitewide-prices.ps1 first'; Exit-Guard -Name 'article-price-edits' -Summary 'blind=no-findings' -Code 3 }
    $slugList = @((Read-JsonFile $fp).pages | ForEach-Object { [string]$_.slug } | Where-Object { $_ -ne '(home)' })
  }
  if (-not (Test-Path $editDir)) { New-Item -ItemType Directory -Path $editDir | Out-Null }
  $rows = @(); $blind = @()
  foreach ($s in $slugList) {
    $b = Get-ApeBase $s
    if (-not $b) { $blind += "$s : no export and the Admin API returned nothing"; continue }
    $h = Get-ApeHtmlOfLexical $b.lexical
    if ($null -eq $h) { $blind += "$s : the body is not a single html card"; continue }
    $f = Get-ApeFigures $h
    $rows += [pscustomobject]@{ slug = $s; id = $b.id; kind = $b.kind; visibility = $b.visibility; title = $b.title; title_has_price = ([regex]::IsMatch([string]$b.title, '\$\d')); base_updated_at = $b.updated_at; base_source = $b.source; base_lexical_sha256 = (Get-ApeSha $b.lexical); figures = $f; figure_count = $f.Count; monitor_shape_count = @($f | Where-Object { $_.monitor_shape }).Count }
    $bf = Join-Path $editDir ($s + '.base.json')
    [IO.File]::WriteAllText($bf, ([ordered]@{ slug = $s; id = $b.id; kind = $b.kind; title = $b.title; updated_at = $b.updated_at; source = $b.source; lexical = $b.lexical } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
  }
  $doc = [ordered]@{ generated = (Get-Date -Format s); ruling = 'C (Brad, 2026-09-21): live where the article names something the pipeline prices, removed where it does not'; articles = $rows.Count; figures = ($rows | Measure-Object figure_count -Sum).Sum; blind = $blind; rows = $rows }
  [IO.File]::WriteAllText((Join-Path $editDir 'inventory.json'), ($doc | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
  foreach ($r in $rows) { Write-Output ("  {0,-40} figures={1,3} monitor-shape={2,3} title-price={3}" -f $r.slug, $r.figure_count, $r.monitor_shape_count, $r.title_has_price) }
  foreach ($x in $blind) { Write-Output ('BLIND  ' + $x) }
  Exit-Guard -Name 'article-price-edits' -Summary ("inventory articles={0} figures={1} blind={2}" -f $rows.Count, $doc.figures, $blind.Count) -Code $(if ($blind.Count) { 3 } else { 0 })
}

if ($Prepare) {
  $decs = @(Get-ChildItem $editDir -Filter '*.decisions.json' | Where-Object { -not $slugList.Count -or $slugList -contains ($_.Name -replace '\.decisions\.json$', '') })
  $refused = @(); $done = 0
  $pairs = @(); foreach ($d in $decs) { foreach ($e in @((Read-JsonFile $d.FullName).edits)) { foreach ($m in [regex]::Matches([string]$e.replace, '\{\{live-unit:([a-z0-9-]+):([a-z]+)\}\}')) { $pairs += @{ bid = $m.Groups[1].Value; per = $m.Groups[2].Value } } } }
  $unit = @{ values = @{}; asof = '' }; if ($pairs.Count) { $unit = Get-ApeUnitValues $pairs }
  foreach ($d in $decs) {
    $dec = Read-JsonFile $d.FullName; $s = [string]$dec.slug
    $base = Read-JsonFile (Join-Path $editDir ($s + '.base.json'))
    $html = Get-ApeHtmlOfLexical ([string]$base.lexical); $new = $html; $why = @(); $reps = @()
    foreach ($e in @($dec.edits)) {
      $find = [string]$e.find
      $n = ([regex]::Matches($new, [regex]::Escape($find))).Count
      if ($n -ne 1) { $why += ("find occurs {0} times (must be 1): {1}" -f $n, $find.Substring(0, [Math]::Min(80, $find.Length))); continue }
      $rep = [string]$e.replace
      try {
        $rep = [regex]::Replace($rep, '\{\{live-recipe:([a-z0-9-]+)\}\}', [Text.RegularExpressions.MatchEvaluator] { param($m) Get-ApeRecipeSpan $m.Groups[1].Value })
        $rep = [regex]::Replace($rep, '\{\{live-unit:([a-z0-9-]+):([a-z]+)\}\}', [Text.RegularExpressions.MatchEvaluator] { param($m)
          $k = $m.Groups[1].Value + '|' + $m.Groups[2].Value
          if (-not $unit.values.ContainsKey($k)) { throw ("the shipped fill cannot price {0} per {1} from the canonical feed" -f $m.Groups[1].Value, $m.Groups[2].Value) }
          Format-TcLivePriceSpan -Field 'unit_price' -Bid $m.Groups[1].Value -Per $m.Groups[2].Value -Value $unit.values[$k] -AsOf $unit.asof })
      } catch { $why += $_.Exception.Message; continue }
      $new = $new.Replace($find, $rep); $reps += [ordered]@{ find = $find; replace = $rep; class = [string]$e.class }
    }
    if (@(Get-TcLivePriceSpans $new).Count -gt 0 -and -not $new.Contains($SCRIPT_TAG)) { $new = $new.TrimEnd() + "`n" + $SCRIPT_TAG + "`n"; $reps += [ordered]@{ find = '(end of body)'; replace = $SCRIPT_TAG; class = 'script' } }
    $left = @(Find-TcGroceryPriceLiterals (ConvertTo-TcReaderText $new))
    if ($left.Count) { $why += ('still carries ' + $left.Count + ' literal(s) the monitor counts: ' + (($left | ForEach-Object { $_.context }) -join ' || ')) }
    $title = if ($dec.title_new) { [string]$dec.title_new } else { [string]$base.title }
    if ($title -match '\$\d') { $why += ('title still states a price: ' + $title) }
    if ($why.Count) { $refused += ("$s : " + ($why -join ' | ')); continue }
    $newLex = Set-ApeHtmlOfLexical ([string]$base.lexical) $new
    $edit = [ordered]@{ slug = $s; id = $base.id; kind = $base.kind; base_updated_at = $base.updated_at; base_lexical_sha256 = (Get-ApeSha ([string]$base.lexical)); title_old = $base.title; title_new = $title; replacements = $reps; new_lexical_sha256 = (Get-ApeSha $newLex); stamped_against_feed = $unit.asof; prepared = (Get-Date -Format s) }
    [IO.File]::WriteAllText((Join-Path $editDir ($s + '.edit.json')), ($edit | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    $done++
  }
  foreach ($x in $refused) { Write-Output ('REFUSED  ' + $x) }
  Exit-Guard -Name 'article-price-edits' -Summary ("prepare decisions={0} prepared={1} refused={2}" -f $decs.Count, $done, $refused.Count) -Code $(if ($refused.Count) { 1 } else { 0 })
}

if ($Land) {
  $gkey = Get-GhostKey
  $hdr = { @{ Authorization = ('Ghost ' + (Get-GhostJWT -Key $gkey)); 'Accept-Version' = (Get-GhostAcceptVersion); 'Content-Type' = 'application/json' } }
  $edits = @(Get-ChildItem $editDir -Filter '*.edit.json' | Where-Object { -not $slugList.Count -or $slugList -contains ($_.Name -replace '\.edit\.json$', '') })
  $bad = @(); $ok = 0
  foreach ($f in $edits) {
    $e = Read-JsonFile $f.FullName; $res = if ($e.kind -eq 'page') { 'pages' } else { 'posts' }
    $live = @((Invoke-GhostApi -Method GET -Uri ("$API/ghost/api/admin/$res/$($e.id)/?formats=lexical") -Headers (& $hdr) -TimeoutSec 60).$res)[0]
    if ([string]$live.updated_at -ne [string]$e.base_updated_at) { $bad += ("{0}: live updated_at {1} is not the base's {2}; re-run -Inventory and -Prepare" -f $e.slug, $live.updated_at, $e.base_updated_at); continue }
    if ((Get-ApeSha ([string]$live.lexical)) -ne $e.base_lexical_sha256) { $bad += ("{0}: live lexical is not the pinned base" -f $e.slug); continue }
    $h = Get-ApeHtmlOfLexical ([string]$live.lexical)
    foreach ($r in @($e.replacements)) { if ($r.find -eq '(end of body)') { $h = $h.TrimEnd() + "`n" + $r.replace + "`n" } else { $h = $h.Replace([string]$r.find, [string]$r.replace) } }
    $newLex = Set-ApeHtmlOfLexical ([string]$live.lexical) $h
    if ((Get-ApeSha $newLex) -ne $e.new_lexical_sha256) { $bad += ("{0}: the applied lexical does not hash to the prepared one" -f $e.slug); continue }
    $body = @{ $res = @(@{ lexical = $newLex; title = $e.title_new; updated_at = $live.updated_at }) } | ConvertTo-Json -Depth 6 -Compress
    if ($Apply) { Invoke-GhostApi -Method PUT -Uri ("$API/ghost/api/admin/$res/$($e.id)/") -Headers (& $hdr) -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 90 | Out-Null; Write-Output ("LANDED  " + $e.slug) }
    else { Write-Output ("WOULD PUT  {0} {1} title '{2}' ({3} replacement(s))" -f $res, $e.slug, $e.title_new, @($e.replacements).Count) }
    $ok++
  }
  foreach ($x in $bad) { Write-Output ('REFUSED  ' + $x) }
  Exit-Guard -Name 'article-price-edits' -Summary ("land edits={0} ok={1} refused={2} applied={3}" -f $edits.Count, $ok, $bad.Count, [bool]$Apply) -Code $(if ($bad.Count) { 1 } else { 0 })
}
Write-Output 'usage: -Inventory | -Prepare | -Land [-Apply] | -SelfTest'
Exit-Guard -Name 'article-price-edits' -Summary 'no-mode' -Code 3
