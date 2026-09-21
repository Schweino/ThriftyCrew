# price-literal-gate.ps1 - NO PRICE LITERAL SHIPS IN A BUILT RECIPE CARD, and every live placeholder is
# well formed. The build gate of Brad's 2026-09-21 instruction: "The recipe pages should be fetching the
# pricing from our database. That should be a constant and we shouldn't need to 'republish'."
#
# WHAT IT READS: the BUILT OUTPUT (db\built\<slug>.body.html and .head.html), never the spec. The frozen
# number lives in what ships; reanchor-all's "NO $N.NN literal in prose" gate reads spec prose, which is a
# different question, and a renderer that composes a figure out of two clean fields would pass it.
#
# WHAT IT REFUSES
#   1. A money figure in reader-visible text or in a reader-visible attribute (alt, title, aria-label,
#      content, placeholder) that is not inside a live placeholder span. Scripts and styles are code, not
#      copy, and are dropped first; HTML comments too.
#   2. A live placeholder that does not carry this card's slug, a registered field, that field's registered
#      basis, a positive two-decimal fallback, and text equal to that fallback. A placeholder the feed cannot
#      be checked against is a hole the size of the one it replaced.
#   3. A price key in the head's JSON-LD (price, priceCurrency, offers, costPerServing, estimatedCost). The
#      structured data carries no price today; one appearing is a decision nobody took (Brad: SEO is not
#      changed in this stage).
#
# THE ALLOWLIST - exact phrases, each with its reason, never a pattern:
#   "$1 a month"   the site's own membership price, in upsell_html. Not a grocery price, not derived from
#                  any board, and set by Brad. It is the only literal on 584 of 584 built cards (2026-09-21).
#   "$10 a year"   the annual membership price, same reasoning; not on any card today, allowed so the
#                  upsell may name it without a gate change.
# A STATED BOUND ("under $3 a serving") needs no entry: it never reaches a built card, because
# Remove-GhostStaticCurrencyClaims rewrites every figure that is not a live span into words at render. If a
# bound ever should ship as a figure, that is a ruling, and it gets its own named phrase here.
#
# NOT COVERED, stated: a price written in words ("six dollars") and a figure an image carries. The
# spellings it knows are $N, &#36;N, &#x24;N, &dollar;N, N dollars, N cents and N followed by the cent sign.
#
# Dot-source:  . (Join-Path $mp 'lib\price-literal-gate.ps1')     then Test-TcBuiltPriceLiterals
# Corpus:      powershell -File meal-prep\lib\price-literal-gate.ps1 -Corpus [-CorpusSlugs a,b] [-CorpusRequireAsOf]
# Self-test:   powershell -File meal-prep\lib\price-literal-gate.ps1 -SelfTest
# The corpus parameters carry a Corpus prefix ON PURPOSE: engine\publish.ps1 and build-card2 DOT-SOURCE this
# file, and a dot-sourced param block rebinds its names in the caller's scope - a plain -Slugs here would
# silently reset publish.ps1's own $Slugs to ''.
param([switch]$SelfTest, [switch]$Corpus, [string]$CorpusSlugs = '', [string]$CorpusBuiltDir = '', [switch]$CorpusRequireAsOf)

# CAPTURE THE SWITCHES BEFORE THE DOT-SOURCE: render-tokens.ps1 has its own param([switch]$SelfTest), and
# dot-sourcing it rebinds $SelfTest to false in THIS scope - the self-test then exits 0 having run nothing.
$SelfTestPlg = $SelfTest.IsPresent; $plgCorpus = $Corpus.IsPresent; $plgAsOf = $CorpusRequireAsOf.IsPresent
. (Join-Path $PSScriptRoot 'render-tokens.ps1')   # $script:TC_LIVE_PRICE_BASIS + Format-TcLivePriceSpan: ONE registry

$script:TC_PRICE_ALLOWLIST = @('$1 a month', '$10 a year')
$script:TC_SPAN_RE = '<span\s+data-tc-live-price\b([^>]*)>([^<]*)</span>'
$script:TC_MONEY_RE = '(?i)(?:\$|&#0*36;|&#x0*24;|&dollar;)\s?\d|\b\d[\d,]*(?:\.\d+)?\s*(?:dollars?|cents?)\b|\d\s*(?:\u00A2|&cent;|&#162;)'

function Get-TcSpanAttr { param([string]$Attrs, [string]$Name)
  $m = [regex]::Match($Attrs, '\b' + [regex]::Escape($Name) + '="([^"]*)"')
  if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}

function Get-TcLivePriceSpans { param([string]$Html)
  $out = @()
  foreach ($m in [regex]::Matches($Html, $script:TC_SPAN_RE)) {
    $a = $m.Groups[1].Value
    $out += [pscustomobject]@{ raw = $m.Value; slug = (Get-TcSpanAttr $a 'data-tc-slug'); field = (Get-TcSpanAttr $a 'data-tc-field')
                               basis = (Get-TcSpanAttr $a 'data-tc-basis'); fallback = (Get-TcSpanAttr $a 'data-tc-fallback'); asof = (Get-TcSpanAttr $a 'data-tc-asof'); text = $m.Groups[2].Value }
  }
  return ,$out
}

function Remove-TcCode { param([string]$Html)
  $h = [regex]::Replace($Html, '(?is)<script\b.*?</script>', ' ')
  $h = [regex]::Replace($h, '(?is)<style\b.*?</style>', ' ')
  return [regex]::Replace($h, '(?s)<!--.*?-->', ' ')
}

function Find-TcMoney { param([string]$Text, [string]$Where)
  $t = $Text
  foreach ($p in $script:TC_PRICE_ALLOWLIST) { $t = $t.Replace($p, ' ') }
  $f = @()
  foreach ($m in [regex]::Matches($t, $script:TC_MONEY_RE)) {
    $s = [math]::Max(0, $m.Index - 50); $e = [math]::Min($t.Length, $m.Index + $m.Length + 40)
    $f += ($Where + ': price literal outside a live placeholder -> "' + ($t.Substring($s, $e - $s) -replace '\s+', ' ').Trim() + '"')
  }
  return ,$f
}

# Returns the list of findings; an empty list means the card may ship.
# -RequireAsOf is the PUBLISH-time form: every span must carry the data-tc-asof stamp build-cards writes when it
# replaces build-card2's provisional fallback with the value the card's own script filled (same basis).
function Test-TcBuiltPriceLiterals { param([string]$Body, [string]$Head = '', [string]$Slug, [switch]$RequireAsOf)
  $f = @()
  $code = Remove-TcCode $Body
  # (2) every placeholder is well formed, and names THIS card
  $spans = Get-TcLivePriceSpans $code
  foreach ($s in $spans) {
    $why = @()
    if ($s.slug -ne $Slug) { $why += ("slug '" + $s.slug + "' is not this card's '" + $Slug + "'") }
    if (-not $s.field -or -not $script:TC_LIVE_PRICE_BASIS.ContainsKey($s.field)) { $why += ("field '" + $s.field + "' is not in the live-price registry") }
    elseif ($s.basis -ne $script:TC_LIVE_PRICE_BASIS[$s.field]) { $why += ("basis '" + $s.basis + "' is not the registered basis '" + $script:TC_LIVE_PRICE_BASIS[$s.field] + "' for " + $s.field) }
    $d = 0.0
    if (-not $s.fallback -or $s.fallback -notmatch '^\d+\.\d{2}$' -or -not [double]::TryParse($s.fallback, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -or -not ($d -gt 0)) {
      $why += ("fallback '" + $s.fallback + "' is not a positive two-decimal price")
    } elseif ($s.text -ne ('~$' + $s.fallback)) { $why += ("text '" + $s.text + "' is not the fallback ~$" + $s.fallback) }
    if ($RequireAsOf -and $s.asof -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$') { $why += 'no data-tc-asof stamp: the fallback was never replaced by the card''s own fill, so its basis is unproven (run engineuild-cards.ps1)' }
    if ($why.Count) { $f += ('placeholder: ' + ($why -join '; ') + ' -> ' + $s.raw) }
  }
  $bare = $code
  $bare = [regex]::Replace($bare, $script:TC_SPAN_RE, ' ')
  if ($bare -match 'data-tc-live-price') { $f += 'placeholder: a data-tc-live-price element that is not a plain <span> with text only - the fill and this gate cannot read it' }
  # (1) reader-visible attributes, then reader-visible text
  foreach ($am in [regex]::Matches($bare, '(?i)\s(?:alt|title|aria-label|content|placeholder)\s*=\s*("[^"]*"|''[^'']*'')')) {
    $f += (Find-TcMoney $am.Groups[1].Value 'attribute')
  }
  $text = [regex]::Replace($bare, '<[^>]+>', ' ')
  $f += (Find-TcMoney $text 'body')
  # (3) the head: its JSON-LD carries no price key, and nothing in it states a figure
  if ($Head) {
    foreach ($jm in [regex]::Matches($Head, '(?is)<script[^>]*application/ld\+json[^>]*>(.*?)</script>')) {
      if ($jm.Groups[1].Value -match '"(?:price|priceCurrency|offers|costPerServing|estimatedCost)"\s*:') { $f += ('head: the JSON-LD carries a price key (' + $Matches[0] + ') - structured data is not a price surface without a ruling') }
      $f += (Find-TcMoney $jm.Groups[1].Value 'head JSON-LD')
    }
    $f += (Find-TcMoney ([regex]::Replace((Remove-TcCode $Head), '<[^>]+>', ' ')) 'head')
  }
  return ,@($f | Where-Object { $_ })
}

if ($plgCorpus) {
  . (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'lib\guard-contract.ps1')
  $dir = if ($CorpusBuiltDir) { $CorpusBuiltDir } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'db\built' }
  $want = @($CorpusSlugs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $files = @(Get-ChildItem (Join-Path $dir '*.body.html') -ErrorAction SilentlyContinue)
  if ($want.Count) { $files = @($files | Where-Object { $want -contains ($_.Name -replace '\.body\.html$', '') }) }
  if (-not $files.Count) { Write-Output ("PRICE-LITERALS: BLIND - no built card resolved under $dir" + $(if ($want.Count) { ' for ' + ($want -join ',') })); Exit-Guard -Name 'price-literals' -Summary 'scanned=0 blind' -Code 3 }
  $bad = 0; $nf = 0
  foreach ($bf in $files) {
    $slug = $bf.Name -replace '\.body\.html$', ''
    $hp = Join-Path $dir ($slug + '.head.html')
    $head = if (Test-Path $hp) { [IO.File]::ReadAllText($hp, [Text.Encoding]::UTF8) } else { '' }
    $fs = Test-TcBuiltPriceLiterals -Body ([IO.File]::ReadAllText($bf.FullName, [Text.Encoding]::UTF8)) -Head $head -Slug $slug -RequireAsOf:$plgAsOf
    if ($fs.Count) { $bad++; $nf += $fs.Count; foreach ($x in ($fs | Select-Object -First 3)) { Write-Output ("  $slug  $x") } }
  }
  Write-Output ("price-literals: scanned {0} built card(s), {1} with findings ({2} finding(s))" -f $files.Count, $bad, $nf)
  Exit-Guard -Name 'price-literals' -Summary ("scanned={0} cards_with_findings={1} findings={2}" -f $files.Count, $bad, $nf) -Code $(if ($bad) { 1 } else { 0 })
}

if ($SelfTestPlg) {
  $script:fails = 0; $n = 0
  function T($m, $c, $g) { $script:n++; if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:fails++ } }
  $sp = Format-TcLivePriceSpan -Slug 'turkey-wild-rice-casserole' -Value '6.20'
  $clean = '<p class="smp-stat"><strong>Makes 14 servings &middot; ~579 cal &middot; ' + $sp + '.</strong></p><p>About <strong>' + $sp + ' a serving</strong> (at everyday cost).</p><script>var x=''~$''+(1).toFixed(2); TC.money=function(v){return ''$''+v;};</script><style>.a:before{content:"$5"}</style><p><em>Members get every recipe for $1 a month.</em></p>'
  $headClean = '<script type="application/ld+json">{"@type":"Recipe","description":"579 calories, 48g protein, with live pricing shown on the page.","nutrition":{"calories":"579 calories"}}</script>'
  $r = Test-TcBuiltPriceLiterals -Body $clean -Head $headClean -Slug 'turkey-wild-rice-casserole'
  T 'MUST NOT FIRE  a clean card: placeholders, script and style code, and the membership price' ($r.Count -eq 0) ($r -join ' | ')

  # MUST FIRE - THE FOUNDING BUG, verbatim: the frozen "$2.40 each" sentence.
  $r = Test-TcBuiltPriceLiterals -Body ($clean + '<p>Fourteen servings at about $2.40 each. Dinner sorted, money saved.</p>') -Slug 'turkey-wild-rice-casserole'
  T 'MUST FIRE  the frozen "Fourteen servings at about $2.40 each" sentence is refused' ($r.Count -eq 1 -and $r[0] -match '2\.40 each') ($r -join ' | ')
  # MUST FIRE - the members-half per-line figure Brad quoted from the spec
  $r = Test-TcBuiltPriceLiterals -Body ('<!--TC-PAYWALL--><li>Parmesan Cheese, 2.25 oz: ~$0.76. <strong>Buy 1 8oz tub: $2.74.</strong></li>') -Slug 'x'
  T 'MUST FIRE  a per-line spec figure behind the paywall is refused (both numbers)' ($r.Count -eq 2) ($r -join ' | ')
  foreach ($enc in @('&#36;3.69 per bowl', '&#x24;3.69 per bowl', '&dollar;3.69 per bowl', '51.72 dollars for the batch', '69 cents a bowl')) {
    $r = Test-TcBuiltPriceLiterals -Body ('<p>' + $enc + '</p>') -Slug 'x'
    T ('MUST FIRE  an encoded or spelled figure is refused: ' + $enc) ($r.Count -ge 1) ($r -join ' | ')
  }
  $r = Test-TcBuiltPriceLiterals -Body '<img alt="a $4.10 bowl" src="x.png">' -Slug 'x'
  T 'MUST FIRE  a figure in a reader-visible attribute (alt) is refused' ($r.Count -eq 1) ($r -join ' | ')
  $r = Test-TcBuiltPriceLiterals -Body $clean -Head '<script type="application/ld+json">{"@type":"Recipe","estimatedCost":{"@type":"MonetaryAmount","value":"86.85"}}</script>' -Slug 'turkey-wild-rice-casserole'
  T 'MUST FIRE  a price key in the JSON-LD is refused' ($r.Count -ge 1 -and ($r -join ' ') -match 'estimatedCost') ($r -join ' | ')
  # MUST FIRE - malformed placeholders
  $r = Test-TcBuiltPriceLiterals -Body $sp -Slug 'chicken-fried-rice-skillet'
  T 'MUST FIRE  a placeholder naming ANOTHER recipe is refused' ($r.Count -eq 1 -and $r[0] -match 'not this card') ($r -join ' | ')
  $r = Test-TcBuiltPriceLiterals -Body ($sp.Replace('data-tc-field="cost_ps"', 'data-tc-field="cost_batch"')) -Slug 'turkey-wild-rice-casserole'
  T 'MUST FIRE  a placeholder naming a field outside the registry is refused' ($r.Count -eq 1 -and $r[0] -match 'registry') ($r -join ' | ')
  $r = Test-TcBuiltPriceLiterals -Body ($sp.Replace('feed-everyday-whole-package', 'utilization')) -Slug 'turkey-wild-rice-casserole'
  T 'MUST FIRE  a placeholder whose basis is not the field''s registered basis is refused' ($r.Count -eq 1 -and $r[0] -match 'basis') ($r -join ' | ')
  $r = Test-TcBuiltPriceLiterals -Body '<span data-tc-live-price>current release price loading</span>' -Slug 'x'
  T 'MUST FIRE  the pre-2026-09-21 placeholder (no slug, no fallback, "loading" copy) is refused' ($r.Count -eq 1 -and $r[0] -match 'fallback') ($r -join ' | ')
  $r = Test-TcBuiltPriceLiterals -Body ($sp.Replace('>~$6.20<', '>~$5.00<')) -Slug 'turkey-wild-rice-casserole'
  T 'MUST FIRE  a placeholder whose text is not its own fallback is refused' ($r.Count -eq 1 -and $r[0] -match 'text') ($r -join ' | ')
  $r = Test-TcBuiltPriceLiterals -Body ($sp.Replace('data-tc-fallback="6.20">~$6.20', 'data-tc-fallback="0.00">~$0.00')) -Slug 'turkey-wild-rice-casserole'
  T 'MUST FIRE  a $0.00 fallback is refused (the bar is > 0; 0.00 is one cent below the smallest price)' ($r.Count -eq 1) ($r -join ' | ')
  $r = Test-TcBuiltPriceLiterals -Body ((Format-TcLivePriceSpan -Slug 'x' -Value '0.01')) -Slug 'x'
  T 'AT BAR  a 0.01 fallback, exactly one cent above the > 0 bar, ships' ($r.Count -eq 0) ($r -join ' | ')
  $r = Test-TcBuiltPriceLiterals -Body '<span data-tc-live-price data-tc-slug="x"><b>~$1.00</b></span>' -Slug 'x'
  T 'MUST FIRE  a placeholder with markup inside it is refused (neither the fill nor this gate can read it)' ($r.Count -ge 1) ($r -join ' | ')
  $r = Test-TcBuiltPriceLiterals -Body $sp -Slug 'turkey-wild-rice-casserole' -RequireAsOf
  T 'MUST FIRE  at publish, a span still carrying build-card2''s provisional (unstamped) fallback is refused' ($r.Count -eq 1 -and $r[0] -match 'asof') ($r -join ' | ')
  $r = Test-TcBuiltPriceLiterals -Body (Format-TcLivePriceSpan -Slug 'turkey-wild-rice-casserole' -Value '5.87' -AsOf '2026-09-21T05:22:59') -Slug 'turkey-wild-rice-casserole' -RequireAsOf
  T 'MUST NOT FIRE  at publish, a span stamped from the card''s own fill ships' ($r.Count -eq 0) ($r -join ' | ')
  # MUST NOT FIRE - legal inputs
  $r = Test-TcBuiltPriceLiterals -Body '<p>Members get everything for $1 a month, or $10 a year.</p>' -Slug 'x'
  T 'MUST NOT FIRE  the two allowlisted membership phrases' ($r.Count -eq 0) ($r -join ' | ')
  $r = Test-TcBuiltPriceLiterals -Body '<p>Members get everything for $1 a week.</p>' -Slug 'x'
  T 'MUST FIRE  the allowlist is exact phrases: "$1 a week" is not "$1 a month"' ($r.Count -eq 1) ($r -join ' | ')
  $r = Test-TcBuiltPriceLiterals -Body '<p>Makes 14 servings, 579 calories, 48g protein, 2.25 oz of parmesan, 350 F for 40 minutes.</p>' -Slug 'x'
  T 'MUST NOT FIRE  numbers that are not money (servings, calories, grams, ounces, degrees)' ($r.Count -eq 0) ($r -join ' | ')
  # CLEAN TWIN - calories and protein still render (they are build-time and not this gate's business)
  T 'CLEAN TWIN  the clean card still carries its calorie and protein figures' ($clean -match '~579 cal' -and $headClean -match '48g protein') 'lost'

  # THE REAL CORPUS, when there is one: every built card must pass (a worktree without cards says so)
  $dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'db\built'
  $cards = @(Get-ChildItem (Join-Path $dir '*.body.html') -ErrorAction SilentlyContinue)
  if ($cards.Count) { Write-Output ("note  corpus: " + $cards.Count + " built card(s) present; run -Corpus for the data check (this self-test stays hermetic)") }
  if ($script:fails -eq 0) { Write-Output ("price-literal-gate self-test PASS ($script:n cases)"); exit 0 } else { Write-Output ("price-literal-gate self-test FAIL ($script:fails of $script:n cases)"); exit 1 }
}
