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
param([switch]$Inventory, [switch]$Prepare, [switch]$Land, [switch]$Apply, [string]$Slugs = '', [switch]$Refresh, [switch]$SelfTest)
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
  $tight = Find-TcGroceryPriceLiterals $t   # assigned, never wrapped inline: the comma return would read as ONE element.  SPANS: a figure is the monitor's shape only when it sits inside a literal's span
  $out = @()
  foreach ($m in [regex]::Matches($t, '\$\d[\d,]*(?:\.\d+)?')) {
    $a = [Math]::Max(0, $t.LastIndexOfAny([char[]]'.!?', [Math]::Max(0, $m.Index - 1)) + 1); $b = $t.IndexOfAny([char[]]'.!?', $m.Index + $m.Length)
    if ($b -lt 0 -or $b - $a -gt 400) { $b = [Math]::Min($t.Length, $m.Index + 160) }
    $sent = $t.Substring($a, [Math]::Max(0, $b - $a + 1)).Trim()
    $isTight = @($tight | Where-Object { $m.Index -ge $_.index -and ($m.Index + $m.Length) -le ($_.index + $_.length) }).Count -gt 0
    $out += [pscustomobject]@{ figure = $m.Value; sentence = $sent; monitor_shape = $isTight }
  }
  return ,$out
}

# the article's CURRENT base: the adopted export when present, else a read-only Admin API GET (posts, then pages)
function Get-ApeBase { param([string]$Slug)
  $j = Join-Path $adopted ($Slug + '.json')
  $pin0 = Join-Path $editDir ($Slug + '.base.json'); if ((Test-Path $pin0) -and -not $Refresh) { $o = Read-JsonFile $pin0; return [pscustomobject]@{ slug = $Slug; id = $o.id; kind = $o.kind; title = $o.title; visibility = $null; updated_at = $o.updated_at; lexical = [string]$o.lexical; source = [string]$o.source } }
  if (Test-Path $j) { $o = Read-JsonFile $j; return [pscustomobject]@{ slug = $Slug; id = $o.id; kind = $o.kind; title = $o.title; visibility = $o.visibility; updated_at = $o.updated_at; lexical = [string]$o.lexical; source = 'content/ghost-adopted/' + $Slug + '.json (exported ' + $o.exported_on + ')' } }
  $pin = Join-Path $editDir ($Slug + '.base.json')
  if ((Test-Path $pin) -and -not $Refresh) { $o = Read-JsonFile $pin; return [pscustomobject]@{ slug = $Slug; id = $o.id; kind = $o.kind; title = $o.title; visibility = $null; updated_at = $o.updated_at; lexical = [string]$o.lexical; source = [string]$o.source } }   # the PINNED base: decisions were written against it
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

# RANK ORDER AT BUILD. A <ul|ol data-tc-rank="unit_price" data-tc-rank-per="lb"> is written in the order its stamped
# fallbacks give (ties keep the writer's order), each item ranked by its first span in that unit. An item marked
# data-tc-rank-skip, or with no span in the unit, goes to the end with a label. public\tc-live-price.js re-sorts from the
# live feed on load; this is the order a no-script reader and a search engine see, dated by the note's {{rank-asof}}.
function Set-ApeRankOrder { param([string]$Html)
  $moves = @(); $out = [string]$Html
  foreach ($m in [regex]::Matches([string]$Html, '(?s)(<(ul|ol)\b[^>]*\bdata-tc-rank="unit_price"[^>]*>)(.*?)(</\2>)')) {
    $per = [regex]::Match($m.Groups[1].Value, 'data-tc-rank-per="([^"]+)"').Groups[1].Value
    $items = [regex]::Matches($m.Groups[3].Value, '(?s)<li\b[^>]*>.*?</li>')
    $ranked = @(); $tail = @(); $i = 0
    foreach ($it in $items) {
      $t = $it.Value; $skip = [regex]::Match($t, '^<li\b[^>]*\bdata-tc-rank-skip="([^"]*)"').Groups[1].Value
      $sp = [regex]::Match($t, '<span data-tc-live-price\b[^>]*\bdata-tc-per="' + [regex]::Escape($per) + '"[^>]*\bdata-tc-fallback="([0-9.]+)"')
      if ($skip -or -not $sp.Success) {
        $why = if ($skip) { 'not ranked: ' + $skip } else { 'no live price in ' + $per + ', not ranked' }
        if ($t -notmatch 'data-tc-rank-label') { $t = $t -replace '</li>$', ('<span data-tc-rank-label> (' + $why + ')</span></li>') }
        $tail += $t
      } else { $ranked += [pscustomobject]@{ t = $t; v = [double]::Parse($sp.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture); i = $i } }
      $i++
    }
    $sorted = @($ranked | Sort-Object v, i | ForEach-Object { $_.t }) + $tail
    $block = $m.Groups[1].Value + "`n" + ($sorted -join "`n") + "`n" + $m.Groups[4].Value
    if (-not [string]::Equals($block, $m.Value, [StringComparison]::Ordinal)) { $moves += [pscustomobject]@{ find = $m.Value; replace = $block }; $out = $out.Replace($m.Value, $block) }
  }
  return @{ html = $out; moves = $moves }
}

# THE RESIDUE RULE (Brad, 2026-09-22, "Remove derived ones"). After the edits, every money mention left in an article -
# a figure or an amount in words (Find-TcMoneyMentions) - must sit inside a KEPT entry of its decision file whose class
# says why it may stay: restaurant, finance or non-food. The membership phrases stay by name. A total DERIVED from a
# price the same article removed cannot be told from the text ("$150 a month" names none of its inputs), so this does
# not detect one: it makes leaving one a stated, reviewable decision instead of a silence. Returns the findings.
function Get-ApeResidueFindings { param([string]$Text, [object[]]$Kept)
  $f = @(); $cov = @()
  foreach ($k in @($Kept | Where-Object { $_ })) {
    if (@('restaurant', 'finance', 'non-food') -notcontains [string]$k.class) { $f += ("kept '" + $k.match + "' is class '" + $k.class + "': only restaurant, finance and non-food figures stay"); continue }
    $mt = [string]$k.match; if (-not $mt) { continue }
    $p = 0; while (($p = $Text.IndexOf($mt, $p, [StringComparison]::Ordinal)) -ge 0) { $cov += ,@($p, ($p + $mt.Length)); $p += $mt.Length }
  }
  foreach ($ph in @('$1 a month', '$10 a year')) { $p = 0; while (($p = $Text.IndexOf($ph, $p, [StringComparison]::Ordinal)) -ge 0) { $cov += ,@($p, ($p + $ph.Length)); $p += $ph.Length } }
  $mm = Find-TcMoneyMentions $Text
  foreach ($x in $mm) {
    $in = $false; foreach ($c in $cov) { if ($x.index -ge $c[0] -and ($x.index + $x.length) -le $c[1]) { $in = $true; break } }
    if (-not $in) { $f += ('money left with no stated class (a derived total or a price in words goes; restaurant, finance and non-food stay under kept): "' + $x.context.Trim() + '"') }
  }
  return ,$f
}
# THE STORED FIELDS (custom_excerpt, meta_title, meta_description, og_*, twitter_*) cannot hold a live span. One function
# applies the title change and the field edits to them and refuses what is left: a price literal, money with no stated
# class, an excerpt over Ghost's 300. -Prepare runs it on the fields pinned at -Inventory, -Land on the live ones, so a
# field is judged before the edit is written, not first at the PUT (the "$33,000," excerpt of 2026-09-22 was caught by
# hand). Returns @{ updates = changed fields; findings }.
$script:APE_FIELDS = @('custom_excerpt', 'meta_title', 'meta_description', 'og_title', 'og_description', 'twitter_title', 'twitter_description')
function Get-ApeFieldResult { param($Fields, [string]$TitleOld, [string]$TitleNew, [object[]]$FieldEdits, [object[]]$Kept)
  $upd = [ordered]@{}; $bad = @()
  foreach ($fld in $script:APE_FIELDS) {
    $v = [string]$Fields.$fld; if (-not $v) { continue }; $v0 = $v
    if ($TitleOld -and $TitleNew -and $TitleOld -ne $TitleNew) { $v = $v.Replace($TitleOld, $TitleNew) }
    foreach ($x in @($FieldEdits | Where-Object { $_ })) { $v = $v.Replace([string]$x.find, [string]$x.replace) }
    $lf = Find-TcGroceryPriceLiterals $v
    if ($lf.Count) { $bad += ("$fld still carries " + (($lf | ForEach-Object { $_.figure }) -join ', ')) }
    foreach ($x in (Get-ApeResidueFindings $v @($Kept | Where-Object { $_ }))) { $bad += ("$fld " + $x) }
    if ($fld -eq 'custom_excerpt' -and $v.Length -gt 300) { $bad += "custom_excerpt is $($v.Length) chars (Ghost 422 above 300)" }
    if (-not [string]::Equals($v, $v0, [StringComparison]::Ordinal)) { $upd[$fld] = $v }
  }
  return @{ updates = $upd; findings = $bad }
}
# A live span for a decision token, with its fallback STAMPED on the fill's own basis.
function Get-ApeRecipeSpan { param([string]$RecipeSlug)
  $b = Join-Path $mp ('db\built\' + $RecipeSlug + '.body.html')
  if (-not (Test-Path $b)) { throw "recipe '$RecipeSlug' has no built card, so there is no stamped fallback on the fill's basis" }
  $allSp = Get-TcLivePriceSpans ([IO.File]::ReadAllText($b))   # assigned first: a comma return piped straight on is ONE object
  $sp = @($allSp | Where-Object { $_.asof })
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
  $f2 = Get-ApeFigures '<p>Rice runs $1.50 a pound. Membership is $1 a month, and a $4 coffee-shop muffin adds up.</p>'
  T 'MUST NOT FIRE  "$1.50 a pound" is ONE figure, and "$1 a month" / "$4 muffin" beside it are not the monitor''s shape (the text-Contains over-mark)' ($f2.Count -eq 3 -and $f2[0].monitor_shape -and -not $f2[1].monitor_shape -and -not $f2[2].monitor_shape) (($f2 | ForEach-Object { $_.figure + '=' + $_.monitor_shape }) -join ' ')
  $lex2 = Set-ApeHtmlOfLexical $lex '<p>x</p>'
  T 'CLEAN TWIN  a lexical round trip keeps the single html card and changes only its html' ((Get-ApeHtmlOfLexical $lex2) -eq '<p>x</p>') $lex2
  $para = '{"root":{"children":[{"type":"paragraph","children":[]}],"type":"root","version":1}}'
  T 'MUST FIRE  a body that is not one html card is refused, never half-edited' ($null -eq (Get-ApeHtmlOfLexical $para)) ''
  $r1 = Get-ApeResidueFindings 'Cook at home and that saves you $45 a week.' @()
  T 'MUST FIRE  a total derived from removed prices ("saves you $45 a week") with no stated class is refused' ($r1.Count -eq 1) ($r1 -join ' | ')
  $r2 = Get-ApeResidueFindings 'Takeout runs $25 a dinner, and membership is $1 a month.' @([pscustomobject]@{ match = 'Takeout runs $25 a dinner'; class = 'restaurant' })
  T 'MUST NOT FIRE  a restaurant price kept by name, and the membership phrase, pass' ($r2.Count -eq 0) ($r2 -join ' | ')
  $r3 = Get-ApeResidueFindings 'Pack your own for thirty or forty bucks a month.' @([pscustomobject]@{ match = 'thirty or forty bucks'; class = 'derived' })
  T 'MUST FIRE  a price in words cannot be kept as "derived": the class is refused AND the mention stays unclassified (2 findings)' ($r3.Count -eq 2 -and $r3[0] -match 'only restaurant' -and $r3[1] -match 'no stated class') ($r3 -join ' | ')
  $r4 = Get-ApeResidueFindings 'Soups that cost pennies a bowl.' @()
  T 'MUST FIRE  "pennies a bowl" is a price in words' ($r4.Count -eq 1) ($r4 -join ' | ')
  $sp1 = '<span data-tc-live-price data-tc-bid="p2" data-tc-per="lb" data-tc-field="unit_price" data-tc-basis="feed-everyday-per-unit" data-tc-fallback="2.00">~$2.00</span>'
  $sp2 = '<span data-tc-live-price data-tc-bid="p1" data-tc-per="lb" data-tc-field="unit_price" data-tc-basis="feed-everyday-per-unit" data-tc-fallback="1.00">~$1.00</span>'
  $ul = '<ul data-tc-rank="unit_price" data-tc-rank-per="lb">' + "`n" + '<li data-tc-rank-skip="sold by the egg">Eggs</li>' + "`n" + '<li>B ' + $sp1 + '</li>' + "`n" + '<li>A ' + $sp2 + '</li>' + "`n" + '</ul>'
  $ro = Set-ApeRankOrder ('<p>x</p>' + $ul)
  $order = @([regex]::Matches($ro.html, '<li\b[^>]*>(\w+)') | ForEach-Object { $_.Groups[1].Value }) -join ','
  T 'MUST FIRE  the build-time order follows the stamped prices (A 1.00 before B 2.00) with the skipped item last and labelled' ($order -eq 'A,B,Eggs' -and $ro.html -match 'not ranked: sold by the egg' -and @($ro.moves).Count -eq 1) ($order + ' moves=' + @($ro.moves).Count)
  $ro2 = Set-ApeRankOrder $ro.html
  T 'CLEAN TWIN  an already-ranked list is left byte-identical, with no move recorded' ([string]::Equals($ro2.html, $ro.html, [StringComparison]::Ordinal) -and @($ro2.moves).Count -eq 0) (@($ro2.moves).Count)
  $fr1 = Get-ApeFieldResult ([pscustomobject]@{ custom_excerpt = 'Twenty-five real dinners that land under $3 a serving.' }) 'T' 'T' @() @()
  T 'MUST FIRE  a price literal left in a stored field refuses (the same function -Prepare and -Land run)' ($fr1.findings.Count -ge 1 -and ($fr1.findings -join ' ') -match 'custom_excerpt still carries') ($fr1.findings -join ' | ')
  $fr2 = Get-ApeFieldResult ([pscustomobject]@{ custom_excerpt = 'Twenty-five real dinners that land under $3 a serving.'; meta_title = 'Cheap Dinners Under $3 a Serving' }) 'Cheap Dinners Under $3 a Serving' 'Cheap Dinners' @([pscustomobject]@{ find = 'that land under $3 a serving'; replace = 'that cost very little' }) @()
  T 'CLEAN TWIN  a field cleaned by its edit and a title change passes and is carried as an update' ($fr2.findings.Count -eq 0 -and $fr2.updates['custom_excerpt'] -eq 'Twenty-five real dinners that cost very little.' -and $fr2.updates['meta_title'] -eq 'Cheap Dinners') (($fr2.findings -join ' | ') + ' / ' + ($fr2.updates | ConvertTo-Json -Compress))
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
    $pinF = $null; if ((Test-Path $bf) -and -not $Refresh) { $pinF = (Read-JsonFile $bf).fields }
    if (-not $pinF) { if (-not $script:gkey) { $script:gkey = Get-GhostKey }; $res = if ($b.kind -eq 'page') { 'pages' } else { 'posts' }; $lp = @((Invoke-GhostApi -Method GET -Uri ("$API/ghost/api/admin/$res/$($b.id)/") -Headers @{ Authorization = ('Ghost ' + (Get-GhostJWT -Key $script:gkey)); 'Accept-Version' = (Get-GhostAcceptVersion) } -TimeoutSec 60).$res)[0]; $pinF = [ordered]@{}; foreach ($k in $script:APE_FIELDS) { $pinF[$k] = [string]$lp.$k } }
    [IO.File]::WriteAllText($bf, ([ordered]@{ slug = $s; id = $b.id; kind = $b.kind; title = $b.title; updated_at = $b.updated_at; source = $b.source; lexical = $b.lexical; fields = $pinF } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
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
  $fgen = [string](Read-JsonFile (Join-Path $repo 'grocery\out\smp-feed.json')).generated
  $rankAsOf = ([datetime]::Parse($fgen, [Globalization.CultureInfo]::InvariantCulture)).ToString('MMMM d, yyyy', [Globalization.CultureInfo]::InvariantCulture)
  foreach ($d in $decs) {
    $dec = Read-JsonFile $d.FullName; $s = [string]$dec.slug
    $base = Read-JsonFile (Join-Path $editDir ($s + '.base.json'))
    $html = Get-ApeHtmlOfLexical ([string]$base.lexical); $new = $html; $why = @(); $reps = @()
    foreach ($e in @($dec.edits)) {
      $find = [string]$e.find
      $n = ([regex]::Matches($new, [regex]::Escape($find))).Count
      if ($n -ne 1) { $why += ("find occurs {0} times (must be 1): {1}" -f $n, $find.Substring(0, [Math]::Min(80, $find.Length))); continue }
      $rep = ([string]$e.replace).Replace('{{rank-asof}}', $rankAsOf)
      try {
        $rep = [regex]::Replace($rep, '\{\{live-recipe:([a-z0-9-]+)\}\}', [Text.RegularExpressions.MatchEvaluator] { param($m) Get-ApeRecipeSpan $m.Groups[1].Value })
        $rep = [regex]::Replace($rep, '\{\{live-unit:([a-z0-9-]+):([a-z]+)\}\}', [Text.RegularExpressions.MatchEvaluator] { param($m)
          $k = $m.Groups[1].Value + '|' + $m.Groups[2].Value
          if (-not $unit.values.ContainsKey($k)) { throw ("the shipped fill cannot price {0} per {1} from the canonical feed" -f $m.Groups[1].Value, $m.Groups[2].Value) }
          Format-TcLivePriceSpan -Field 'unit_price' -Bid $m.Groups[1].Value -Per $m.Groups[2].Value -Value $unit.values[$k] -AsOf $unit.asof })
      } catch { $why += $_.Exception.Message; continue }
      $new = $new.Replace($find, $rep); $reps += [ordered]@{ find = $find; replace = $rep; class = [string]$e.class }
    }
    # a RANKED list is written in the order its stamped prices give today, so a no-script reader sees a true, dated order
    $rk = Set-ApeRankOrder $new
    foreach ($mv in $rk.moves) { $reps += [ordered]@{ find = $mv.find; replace = $mv.replace; class = 'rank' } }
    $new = $rk.html
    $liveSpans = Get-TcLivePriceSpans $new   # assigned first: @() around the call counted an empty result as 1 and tagged every article
    if ($liveSpans.Count -gt 0 -and -not $new.Contains($SCRIPT_TAG)) { $new = $new.TrimEnd() + "`n" + $SCRIPT_TAG + "`n"; $reps += [ordered]@{ find = '(end of body)'; replace = $SCRIPT_TAG; class = 'script' } }
    $left = Find-TcGroceryPriceLiterals (ConvertTo-TcReaderText $new)   # assigned, never @()-wrapped: an empty result would count 1
    if ($left.Count) { $why += ('still carries ' + $left.Count + ' literal(s) the monitor counts: ' + (($left | ForEach-Object { $_.context }) -join ' || ')) }
    # EVERY OTHER MONEY MENTION needs a stated class (Brad 2026-09-22, "Remove derived ones"): see Get-ApeResidueFindings
    $kept = @($dec.kept | Where-Object { $_ })
    foreach ($x in (Get-ApeResidueFindings (ConvertTo-TcReaderText $new) $kept)) { $why += $x }
    $title = if ($dec.title_new) { [string]$dec.title_new } else { [string]$base.title }
    if ($title -match '\$\d') { $why += ('title still states a price: ' + $title) }
    # the stored text fields (custom_excerpt, meta/og/twitter) cannot hold a live span, so a figure there is removed by a field edit
    $fe = @($dec.field_edits | Where-Object { $_ })
    foreach ($x in $fe) { $l2 = Find-TcGroceryPriceLiterals ([string]$x.replace); if ($l2.Count) { $why += ('field edit still carries a literal: ' + $x.replace) } }
    if (-not $base.fields) { $why += 'no pinned stored fields: run -Inventory to pin them' }
    else { $fr = Get-ApeFieldResult $base.fields ([string]$base.title) $title $fe $kept; foreach ($x in $fr.findings) { $why += $x } }
    if ($why.Count) { $refused += ("$s : " + ($why -join ' | ')); continue }
    $newLex = Set-ApeHtmlOfLexical ([string]$base.lexical) $new
    $edit = [ordered]@{ slug = $s; id = $base.id; kind = $base.kind; base_updated_at = $base.updated_at; base_lexical_sha256 = (Get-ApeSha ([string]$base.lexical)); title_old = $base.title; title_new = $title; replacements = $reps; field_edits = $fe; kept = $kept; new_lexical_sha256 = (Get-ApeSha $newLex); stamped_against_feed = $unit.asof; prepared = (Get-Date -Format s) }
    [IO.File]::WriteAllText((Join-Path $editDir ($s + '.edit.json')), ($edit | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    $done++
  }
  foreach ($x in $refused) { Write-Output ('REFUSED  ' + $x) }
  Exit-Guard -Name 'article-price-edits' -Summary ("prepare decisions={0} prepared={1} refused={2}" -f $decs.Count, $done, $refused.Count) -Code $(if ($refused.Count) { 1 } else { 0 })
}

if ($Land) {
  $gkey = Get-GhostKey
  $hdr = { @{ Authorization = ('Ghost ' + (Get-GhostJWT -Key $gkey)); 'Accept-Version' = (Get-GhostAcceptVersion); 'Content-Type' = 'application/json' } }
  $feedLive = Invoke-RestMethod -Uri ('https://feed.thriftycrew.com/smp-feed.json?cb=' + [guid]::NewGuid().ToString('N')) -TimeoutSec 60
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
    # every placeholder must be fillable by the DEPLOYED feed, or the article waits: a recipe span needs recipes[slug].everyday_ps
    # (the landing's feed key) and the recipe itself live; a commodity span needs pricing_inputs[bid]
    $unfill = @()
    foreach ($m in [regex]::Matches($h, '<span data-tc-live-price\b([^>]*)>')) {
      $a = $m.Groups[1].Value; $fld = Get-TcSpanAttr $a 'data-tc-field'
      if ($fld -eq 'cost_ps') { $rs = Get-TcSpanAttr $a 'data-tc-slug'; $rv = if ($feedLive.recipes) { $feedLive.recipes.PSObject.Properties[$rs] } else { $null }; if (-not $rv -or -not ([double]$rv.Value.everyday_ps -gt 0)) { $unfill += "recipe $rs" } }
      elseif ($fld -eq 'unit_price') { $bd = Get-TcSpanAttr $a 'data-tc-bid'; if (-not $feedLive.pricing_inputs.PSObject.Properties[$bd]) { $unfill += "commodity $bd" } }
      else { $unfill += "field $fld" }
    }
    if ($unfill.Count) { $bad += ("{0}: the deployed feed cannot fill {1}; land it after the feed carries them" -f $e.slug, (($unfill | Select-Object -Unique) -join ', ')); continue }
    $upd = [ordered]@{ lexical = $newLex; title = $e.title_new; updated_at = $live.updated_at }
    $fr = Get-ApeFieldResult $live $e.title_old $e.title_new @($e.field_edits) @($e.kept)   # the SAME refusal -Prepare runs on the pinned fields
    $fbad = $fr.findings; foreach ($k in $fr.updates.Keys) { $upd[$k] = $fr.updates[$k] }
    if ($fbad.Count) { $bad += ("{0}: {1}" -f $e.slug, ($fbad -join '; ')); continue }
    $body = @{ $res = @($upd) } | ConvertTo-Json -Depth 6 -Compress
    if ($Apply) { Invoke-GhostApi -Method PUT -Uri ("$API/ghost/api/admin/$res/$($e.id)/") -Headers (& $hdr) -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 90 | Out-Null; Write-Output ("LANDED  " + $e.slug) }
    else { Write-Output ("WOULD PUT  {0} {1} title '{2}' ({3} replacement(s); fields: {4})" -f $res, $e.slug, $e.title_new, @($e.replacements).Count, ((@($upd.Keys) | Where-Object { $_ -notin 'lexical','title','updated_at' }) -join ',')) }
    $ok++
  }
  foreach ($x in $bad) { Write-Output ('REFUSED  ' + $x) }
  Exit-Guard -Name 'article-price-edits' -Summary ("land edits={0} ok={1} refused={2} applied={3}" -f $edits.Count, $ok, $bad.Count, [bool]$Apply) -Code $(if ($bad.Count) { 1 } else { 0 })
}
Write-Output 'usage: -Inventory | -Prepare | -Land [-Apply] | -SelfTest'
Exit-Guard -Name 'article-price-edits' -Summary 'no-mode' -Code 3
