# monitor-sitewide-prices.ps1 - THE SITE-WIDE PRICE MONITOR: every live page, daily, for a grocery price typed as a
# literal that no feed backs (2026-09-22, design\RCA-holistic-2026-09-22.md F1; Brad 2026-09-21: "We should never
# have hand-typed pricing. The pricing must be fetched from a store always.").
#
# WHY. monitor-live-recipe-prices and audit-live-price-contract read the engine recipes only. Outside them, and
# outside every gate, sat 45 articles, the pre-engine recipe posts and the homepage quote, each a second copy of a
# board price with nothing comparing the two. This is the reconciler for that class: it asks every live page.
#
# WHAT IT READS. Every <loc> in Ghost's own sitemap-posts.xml and sitemap-pages.xml (the live URL set, by Ghost's
# word), plus the homepage, whose site-wide code injection writes its quote card from a script and so is read WITH
# its scripts (every other page is read without them, or every page would report the homepage quote). Anonymous,
# cache-busted GETs. Nothing here writes to Ghost.
#
# WHAT IS A FINDING. The literal is defined ONCE in meal-prep\lib\sitewide-price-lib.ps1 (a dollar figure attached
# to a food unit or a store; a figure inside a live placeholder is not a literal). Pages the pipeline generates are
# exempt BY NAME in meal-prep\db\sitewide-price-monitor.json, each with its producer and road. The rest are held to a
# RATCHET set on the day this shipped (never a check red on day one): a finding is a literal that was not there
# then - a new page, a page with more literals than its mark, a new title price, or more pages than the mark.
#
# SCOPE OF A CLEAN REPORT: UNSOUND. It knows the spellings in the lib and nothing else ("a $5 bird" passes), and it
# reads the anonymous page, so a figure behind a paywall is out of its reach. A clean run proves no NEW literal of a
# known shape on a public page; it does not prove the site free of typed prices. A finding is complete for its
# shape: the figure is on the live page, attached to a grocery unit.
#
# RESOLVER: meal-prep\pipeline\prepare-article-price-edits.ps1 reads this run's findings file
# (grocery\out\sitewide-price-literals.json) into a per-article worklist and a prepared edit (ruling C: live where
# the pipeline prices it, removed where it does not). Registered in grocery\alert-registry.json.
#
# Exit 0 clean (at or under the mark), 1 findings, 3 could not evaluate (a sitemap unreadable, or a page that could
# not be read twice). Last line: SITEWIDE-PRICES-COMPLETE.
# Usage: monitor-sitewide-prices.ps1 [-NoAlert] [-ProposeBaseline <file>] | -SelfTest
[CmdletBinding()]   # an undeclared argument is a hard error, never a silent $args drop
param([switch]$NoAlert, [string]$ProposeBaseline = '', [int]$DelayMs = 150, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$SelfTestSwp = $SelfTest.IsPresent            # before the dot-sources rebind $SelfTest
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $mp 'lib\sitewide-price-lib.ps1')
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\json-io.ps1')
$SITE = 'https://www.thriftycrew.com'
$cfgPath = Join-Path $mp 'db\sitewide-price-monitor.json'
$outPath = Join-Path $repo 'grocery\out\sitewide-price-literals.json'

# One page's measurement. Pure: the self-test drives it with page bytes.
function Measure-SwpPage { param([string]$Html, [switch]$IsHome)
  $title = [System.Net.WebUtility]::HtmlDecode([regex]::Match([string]$Html, '(?is)<title>(.*?)</title>').Groups[1].Value).Trim()
  $body = if ($IsHome) { [string]$Html } else { Get-TcPageBody $Html }
  $hits = Find-TcGroceryPriceLiterals (ConvertTo-TcReaderText $body -KeepScripts:$IsHome)
  $tHit = [regex]::IsMatch($title, $script:TC_GROCERY_PRICE_RE)
  return [pscustomobject]@{ title = $title; title_hit = $tHit; literals = @($hits).Count; hits = @($hits) }
}

if ($SelfTestSwp) {
  $script:fl = 0; $script:n = 0
  function T($m, $c, $g) { $script:n++; if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + '   got: ' + $g); $script:fl++ } }
  $wrap = { param($b) '<html><head><title>Fixture | Thrifty Crew</title></head><body><article>' + $b + '</article></body></html>' }
  $r = Measure-SwpPage (& $wrap '<p>Fourteen servings at about $2.40 a serving.</p>')
  T 'MUST FIRE  a typed "$2.40 a serving" is a literal' ($r.literals -eq 1) $r.literals
  foreach ($c in @('$2.99/lb chicken thighs', 'eggs were $1.99 at Aldi', 'Fourteen servings at about $2.40 each', 'rice at $0.89 per pound')) {
    $r = Measure-SwpPage (& $wrap ('<p>' + $c + '</p>')); T ('MUST FIRE  "' + $c + '"') ($r.literals -eq 1) $r.literals
  }
  $r = Measure-SwpPage (& $wrap '<p>The 15 year costs you about $617 more each month.</p>')
  T 'MUST NOT FIRE  finance arithmetic "$617 more each month" is not a grocery price' ($r.literals -eq 0) $r.literals
  $r = Measure-SwpPage (& $wrap '<p>You own 100 shares of a company trading at $50 each, and three overdraft fees at $35 each.</p>')
  T 'MUST NOT FIRE  "shares at $50 each" (each without servings is finance, measured on the first live run)' ($r.literals -eq 0) $r.literals
  $sp = '<span data-tc-live-price data-tc-slug="free-chicken-alfredo" data-tc-field="cost_ps" data-tc-basis="feed-everyday-whole-package" data-tc-fallback="2.40" data-tc-asof="2026-09-22T08:14:34">~$2.40</span>'
  $r = Measure-SwpPage (& $wrap ('<p>Fourteen servings at about ' + $sp + ' a serving.</p>'))
  T 'MUST NOT FIRE  a data-tc-live-price span is filled from the feed, not a literal' ($r.literals -eq 0) $r.literals
  $r = Measure-SwpPage (& $wrap ('<p>about ' + $sp + ' a serving, or $1.99/lb for the thighs</p>'))
  T 'MUST FIRE  a literal beside a live span is still a literal (the span removal is not a page pass)' ($r.literals -eq 1) $r.literals
  $r = Measure-SwpPage (& $wrap '<script>var q="$2.40 a serving";</script><p>no price here</p>')
  T 'MUST NOT FIRE  a script on an ordinary page is code, not copy (else every page reports the site injection)' ($r.literals -eq 0) $r.literals
  $homeHtml = '<html><head><title>Thrifty Crew</title></head><body><main>hi</main><script>card.innerHTML="Fourteen servings at about $2.40 each";</script></body></html>'
  $r = Measure-SwpPage $homeHtml -IsHome
  T 'MUST FIRE  the homepage is read WITH its scripts: the injected "$2.40 each" quote is a literal' ($r.literals -eq 1) $r.literals
  $r = Measure-SwpPage ('<html><head><title>Budget Chicken Alfredo Meal Prep: $2.40 a Serving</title></head><body><article><p>x</p></article></body></html>')
  T 'MUST FIRE  a price in the TITLE is a title hit' ($r.title_hit) $r.title
  # exemption: BY NAME from the registry, never by pattern
  $cfg = Read-JsonFile $cfgPath
  $eng = @{ 'chicken-fried-rice-skillet' = $true }
  $why = Get-TcSitewideExemption -Slug 'eggs-price-omaha' -Config $cfg -EngineSlugs $eng
  T 'CLEAN TWIN  a generated page is exempt BY NAME, and the exemption names its producer' ($why -and $why -match 'publish-trend-pages') $why
  $why = Get-TcSitewideExemption -Slug 'chicken-fried-rice-skillet' -Config $cfg -EngineSlugs $eng
  T 'CLEAN TWIN  an engine recipe is exempt through recipes-db membership' ($why -and $why -match 'engine recipe') $why
  $why = Get-TcSitewideExemption -Slug 'lentil-price-omaha' -Config $cfg -EngineSlugs $eng
  T 'MUST FIRE  a page NAMED like a generated one is not exempt (no pattern hole)' ($null -eq $why) $why
  $why = Get-TcSitewideExemption -Slug 'omaha-price-tracker' -Config $cfg -EngineSlugs $eng
  T 'MUST FIRE  a generated page with no road that republishes it (omaha-price-tracker) is not exempt' ($null -eq $why) $why
  # ratchet: the bar is pages_max = 2 with two named pages; at the bar is silent, one page past it fires
  $rat = ('{"pages_max":2,"pages":{"a":{"literals":3,"title":false},"b":{"literals":1,"title":true}}}' | ConvertFrom-Json)
  $v = Get-TcSitewideRatchetVerdict -Measured @{ a = @{ literals = 3; title = $false }; b = @{ literals = 1; title = $true } } -Ratchet $rat
  T 'MUST NOT FIRE  AT the bar: 2 pages against pages_max 2, each at its own mark' ($v.findings.Count -eq 0 -and $v.tighten.Count -eq 0) (($v.findings + $v.tighten) -join ' | ')
  $v = Get-TcSitewideRatchetVerdict -Measured @{ a = @{ literals = 3; title = $false }; b = @{ literals = 1; title = $true }; c = @{ literals = 1; title = $false } } -Ratchet $rat
  T 'MUST FIRE  one page PAST the bar: 3 pages against pages_max 2, the new page named' (($v.findings -join ' ') -match 'NEW\s+c:' -and ($v.findings -join ' ') -match 'COUNT\s+3') ($v.findings -join ' | ')
  $v = Get-TcSitewideRatchetVerdict -Measured @{ a = @{ literals = 3; title = $false }; c = @{ literals = 1; title = $false } } -Ratchet $rat
  T 'MUST FIRE  a new page replacing a fixed one fires even with the total AT the bar' (($v.findings -join ' ') -match 'NEW\s+c:') ($v.findings -join ' | ')
  $v = Get-TcSitewideRatchetVerdict -Measured @{ a = @{ literals = 4; title = $true }; b = @{ literals = 1; title = $true } } -Ratchet $rat
  T 'MUST FIRE  one literal past a page''s own mark (4 > 3) and a new title price' ((($v.findings -join ' ') -match 'GREW\s+a: 4') -and (($v.findings -join ' ') -match 'TITLE\s+a')) ($v.findings -join ' | ')
  $v = Get-TcSitewideRatchetVerdict -Measured @{ a = @{ literals = 2; title = $false } } -Ratchet $rat
  T 'CLEAN TWIN  a page that improved is reported as CAN TIGHTEN, and the fix is never a finding' ($v.findings.Count -eq 0 -and ($v.tighten -join ' ') -match 'a: 2 literal' -and ($v.tighten -join ' ') -match 'b: clean') (($v.findings + $v.tighten) -join ' | ')
  if ($script:fl -eq 0) { Write-Output ("monitor-sitewide-prices self-test PASS ($script:n cases)"); exit 0 } else { Write-Output ("monitor-sitewide-prices self-test FAIL ($script:fl of $script:n)"); exit 1 }
}

$alertLib = Join-Path $repo 'grocery\alert-lib.ps1'
function Send-SwpPage { param([string]$Subject, [string]$Body)
  if ($NoAlert) { Write-Output ('(alert suppressed by -NoAlert) ' + $Subject); return }
  try { . $alertLib; Send-Alert -Subject $Subject -Body $Body -What 'SITEWIDE-PRICES' } catch { Write-Output ('ALERT COULD NOT BE SENT: ' + $_.Exception.Message) }
}
function Get-SwpPage { param([string]$Url)
  for ($i = 0; $i -lt 2; $i++) {
    try { return (Invoke-WebRequest -Uri ($Url + '?cb=' + [guid]::NewGuid().ToString('N')) -UseBasicParsing -TimeoutSec 45).Content } catch { Start-Sleep -Milliseconds 800 }
  }
  return $null
}

$cfg = $null
try { $cfg = Read-JsonFile $cfgPath } catch {}
if (-not $cfg -or -not $cfg.exempt -or -not $cfg.ratchet) {
  Write-Output ('BLIND  ' + $cfgPath + ' is missing or does not parse, so no page can be judged against its exemption or its mark')
  Send-SwpPage 'Sitewide price monitor could not look' ('meal-prep\db\sitewide-price-monitor.json is missing or unparseable; no live page was checked for a typed grocery price today.')
  Exit-Guard -Name 'sitewide-prices' -Summary 'blind=no-config' -Code 3
}
$eng = @{}
try { foreach ($r in (Read-JsonFile (Join-Path $mp 'recipes-db.json')).recipes) { $eng[[string]$r.slug] = $true } } catch {}
if ($eng.Count -eq 0) {
  Send-SwpPage 'Sitewide price monitor could not look' 'meal-prep\recipes-db.json read no recipes, so the engine-recipe exemption has no membership and every recipe page would be misjudged.'
  Exit-Guard -Name 'sitewide-prices' -Summary 'blind=no-engine-membership' -Code 3
}

$urls = New-Object System.Collections.Generic.List[string]
$blind = New-Object System.Collections.Generic.List[string]
foreach ($sm in @('sitemap-posts.xml', 'sitemap-pages.xml')) {
  $x = Get-SwpPage ($SITE + '/' + $sm)
  if (-not $x) { $blind.Add("sitemap $sm could not be read"); continue }
  $locs = [regex]::Matches($x, '<loc>([^<]+)</loc>')
  if ($locs.Count -eq 0) { $blind.Add("sitemap $sm listed no URL") }
  foreach ($m in $locs) { $urls.Add($m.Groups[1].Value.Trim()) }
}
if ($blind.Count) {
  foreach ($b in $blind) { Write-Output ('BLIND  ' + $b) }
  Send-SwpPage 'Sitewide price monitor could not look' (($blind -join "`n") + "`nNo live page was checked for a typed grocery price today.")
  Exit-Guard -Name 'sitewide-prices' -Summary ('blind=sitemap urls=' + $urls.Count) -Code 3
}

$measured = @{}; $pages = @(); $exemptN = 0; $cleanN = 0; $unread = @()
$targets = @([pscustomobject]@{ slug = '(home)'; url = ($SITE + '/'); home = $true }) + @($urls | Select-Object -Unique | ForEach-Object { [pscustomobject]@{ slug = (($_.TrimEnd('/') -split '/')[-1]); url = $_; home = $false } })
foreach ($t in $targets) {
  $why = if ($t.home) { $null } else { Get-TcSitewideExemption -Slug $t.slug -Config $cfg -EngineSlugs $eng }
  if ($why) { $exemptN++; continue }
  $h = Get-SwpPage $t.url
  if (-not $h) { $unread += $t.url; continue }
  $r = Measure-SwpPage $h -IsHome:$t.home
  if ($r.literals -gt 0 -or $r.title_hit) {
    $measured[$t.slug] = @{ literals = $r.literals; title = [bool]$r.title_hit }
    $pages += [pscustomobject]@{ slug = $t.slug; url = $t.url; title = $r.title; title_hit = [bool]$r.title_hit; literals = $r.literals; hits = @($r.hits) }
  } else { $cleanN++ }
  if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
}

$v = Get-TcSitewideRatchetVerdict -Measured $measured -Ratchet $cfg.ratchet
$doc = [ordered]@{ generated = (Get-Date -Format 's'); urls = $targets.Count; exempt = $exemptN; clean = $cleanN; unread = @($unread); findings = @($v.findings); tighten = @($v.tighten); pages = @($pages | Sort-Object slug) }
try { [IO.File]::WriteAllText($outPath, ($doc | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false))) } catch { Write-Output ('findings file could not be written: ' + $_.Exception.Message) }
if ($ProposeBaseline) {
  $pb = [ordered]@{ set = (Get-Date -Format 'yyyy-MM-dd'); pages_max = $measured.Count; pages = [ordered]@{} }
  foreach ($s in @($measured.Keys | Sort-Object)) { $pb.pages[$s] = [ordered]@{ literals = $measured[$s].literals; title = $measured[$s].title } }
  [IO.File]::WriteAllText($ProposeBaseline, ($pb | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
  Write-Output ('proposed baseline (NOT applied) -> ' + $ProposeBaseline)
}

foreach ($p in ($pages | Sort-Object literals -Descending)) { Write-Output ("  {0,3} literal(s)  title={1,-5}  {2}" -f $p.literals, $p.title_hit, $p.slug) }
foreach ($f in $v.findings) { Write-Output ('FINDING  ' + $f) }
if ($v.tighten.Count) { Write-Output ('RATCHET CAN TIGHTEN (the mark is lowered by a person, in a commit): ' + ($v.tighten -join '; ')) }
foreach ($u in $unread) { Write-Output ('UNREAD  ' + $u) }
Write-Output ("sitewide-prices: {0} live URL(s) incl. the homepage: {1} exempt by name, {2} clean, {3} stating a grocery price (mark {4}), {5} could not be read" -f $targets.Count, $exemptN, $cleanN, $pages.Count, $cfg.ratchet.pages_max, $unread.Count)

if ($v.findings.Count) {
  $body = "monitor-sitewide-prices.ps1 read every live page in Ghost's sitemaps and found a grocery price typed as a literal that was not there when the mark was set (" + $cfg.ratchet.set + "):`n`n" + ($v.findings -join "`n") + "`n`n"
  foreach ($p in $pages) { if (($v.findings -join ' ') -match ('\b' + [regex]::Escape($p.slug) + '\b')) { $body += ($p.url + "`n" + ((@($p.hits) | Select-Object -First 5 | ForEach-Object { '    ' + $_.context }) -join "`n") + "`n") } }
  $body += "`nCloses through meal-prep\pipeline\prepare-article-price-edits.ps1, which reads grocery\out\sitewide-price-literals.json into a prepared edit per page (live where the pipeline prices it, removed where it does not)."
  Send-SwpPage ('Sitewide price literals: ' + $v.findings.Count + ' new typed grocery price finding(s)') $body
} elseif ($unread.Count) {
  Send-SwpPage 'Sitewide price monitor could not look' (($unread.Count.ToString() + " live page(s) could not be read twice, so they were not checked for a typed grocery price:`n") + (($unread | Select-Object -First 30) -join "`n"))
}
$code = if ($v.findings.Count) { 1 } elseif ($unread.Count) { 3 } else { 0 }
Exit-Guard -Name 'sitewide-prices' -Summary ("urls={0} exempt={1} clean={2} literal_pages={3} mark={4} findings={5} unexamined={6}" -f $targets.Count, $exemptN, $cleanN, $pages.Count, $cfg.ratchet.pages_max, $v.findings.Count, $unread.Count) -Code $code
