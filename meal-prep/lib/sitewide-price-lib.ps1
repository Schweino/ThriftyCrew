# sitewide-price-lib.ps1 - what a GROCERY PRICE LITERAL on a live page is, and which live pages are exempt from
# the question. ONE definition, read by the daily monitor (pipeline\monitor-sitewide-prices.ps1) and by the article
# lane that turns its findings into prepared edits (pipeline\prepare-article-price-edits.ps1).
#
# WHY (2026-09-22, design\RCA-holistic-2026-09-22.md F1). Every typed price in an article is a second copy of a
# board price with nothing comparing the two. Brad, 2026-09-21: "We should never have hand-typed pricing. The
# pricing must be fetched from a store always." The recipe cards were closed by the live placeholder
# (render-tokens.ps1 Format-TcLivePriceSpan, filled by fillLivePrices); this is the check over every OTHER page.
#
# A PRICE LITERAL is a dollar figure ATTACHED to a food unit or a store: "$0.30 a serving", "$2.99/lb",
# "$3.60 a pound", "$1.99 at Aldi", "servings at about $2.40 each". NOT merely near a food word: the first, looser pattern
# (a figure anywhere near "chicken" or "each") flagged finance arithmetic like "the 15 year costs you about $617
# more each month". "each" counts only after servings: alone it is share prices and fees.
#
# WHAT IS NOT A LITERAL: a figure inside a live placeholder (<span data-tc-live-price ...>), which the feed
# fills at view time. Those spans are removed before matching, whatever their fallback text says.
#
# SCOPE OF A CLEAN READ: UNSOUND. It finds the spellings above and nothing else - "a $5 bird", "The $2
# Bodybuilder Staple", "six dollars", a price in an image all pass it. A clean page is not proven free of a
# typed price; it is free of the shapes this knows. A hit is a real dollar figure attached to a grocery unit
# (complete for that shape), so a finding is worth reading, not a candidate to dismiss.

. (Join-Path $PSScriptRoot 'price-literal-gate.ps1')   # $script:TC_SPAN_RE: the ONE definition of a live placeholder

$script:TC_GROCERY_UNIT = '(?:(?:a|per|an|/)\s*(?:serving|servings|bowl|plate|meal|lb|lbs|pound|oz|ounce|dozen|gallon|jar|box|bag|can)\b|at\s+(?:walmart|aldi|hy-?vee|fareway|sam''?s|baker''?s|family\s+fare)\b)'
# "each" is a unit only after servings ("Fourteen servings at about $2.40 each", the homepage quote): alone it is
# finance ("100 shares at $50 each", "three overdraft fees at $35 each"), measured on the first live run 2026-09-22.
$script:TC_GROCERY_PRICE_RE = '(?i)\$\d+(?:\.\d{1,2})?\s*' + $script:TC_GROCERY_UNIT + '|\bservings?\s+(?:at\s+)?(?:about\s+|around\s+|roughly\s+)?\$\d+(?:\.\d{1,2})?\s*each\b'

# The reader-visible text of an HTML fragment: comments and live placeholders out, scripts and styles out unless
# -KeepScripts (the homepage's site-wide injection writes its quote card FROM a script, so that one target reads
# them), tags to spaces, entities decoded, whitespace collapsed.
function ConvertTo-TcReaderText { param([string]$Html, [switch]$KeepScripts)
  $h = [regex]::Replace([string]$Html, '(?s)<!--.*?-->', ' ')
  $h = [regex]::Replace($h, $script:TC_SPAN_RE, ' ')
  if (-not $KeepScripts) { $h = [regex]::Replace($h, '(?is)<(script|style)\b.*?</\1\s*>', ' ') }
  $h = [regex]::Replace($h, '<[^>]+>', ' ')
  $h = [System.Net.WebUtility]::HtmlDecode($h)
  return ([regex]::Replace($h, '\s+', ' ')).Trim()
}

# The body a reader reads: the first <article>, else <main>, else the whole page (Ghost pages carry no article).
function Get-TcPageBody { param([string]$Html)
  foreach ($tag in 'article', 'main') {
    $m = [regex]::Match([string]$Html, '(?is)<' + $tag + '\b.*?</' + $tag + '\s*>')
    if ($m.Success) { return $m.Value }
  }
  return [string]$Html
}

# Every literal in $Text, each with 60 characters before and 30 after so a reader sees what it prices, and its SPAN
# (index, length). Regex matches never overlap, so the count is one per literal; a caller asking whether some other
# figure is a literal compares SPANS, never text (2026-09-22: a text Contains marked "$1 a month" as a literal because
# "$1.50 a pound" contains "$1"; the monitor's count was never affected).
function Find-TcGroceryPriceLiterals { param([string]$Text)
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($m in [regex]::Matches([string]$Text, $script:TC_GROCERY_PRICE_RE)) {
    $a = [Math]::Max(0, $m.Index - 60); $b = [Math]::Min($Text.Length, $m.Index + $m.Length + 30)
    $out.Add([pscustomobject]@{ figure = $m.Value; context = $Text.Substring($a, $b - $a); index = $m.Index; length = $m.Length })
  }
  return ,$out.ToArray()
}

# THE EXEMPTION REGISTRY (meal-prep\db\sitewide-price-monitor.json, 'exempt'). A page the pipeline GENERATES from
# the board is exempt BY NAME, each entry naming its producer and the road that keeps it current - never a
# pattern, because a pattern ("*-price-omaha") would also exempt a hand-written page someone names that way.
# The engine recipes are the one class entry, and its membership is a FILE (recipes-db.json), not a pattern.
# Returns the reason, or $null when the page is not exempt.
function Get-TcSitewideExemption { param([string]$Slug, $Config, [hashtable]$EngineSlugs)
  if ($Config -and $Config.exempt -and $Config.exempt.pages -and $Config.exempt.pages.PSObject.Properties[$Slug]) {
    $e = $Config.exempt.pages.PSObject.Properties[$Slug].Value
    return ('generated by ' + [string]$e.producer + ': ' + [string]$e.why)
  }
  if ($EngineSlugs -and $EngineSlugs.ContainsKey($Slug)) {
    return ('engine recipe (' + [string]$Config.exempt.engine_recipes.membership + '): ' + [string]$Config.exempt.engine_recipes.why)
  }
  return $null
}

# THE RATCHET VERDICT. Pure. $Measured: slug -> @{ literals = n; title = bool }, non-exempt pages that carry at least
# one literal or a title hit. $Ratchet: the config's 'ratchet' block (pages_max, pages{ slug: { literals, title } }).
# A finding is a price literal that was NOT there when the mark was set: a page outside the baseline, a baseline page
# with MORE literals than its mark, a title hit on a page whose mark had none, or more pages than pages_max. A page
# that improved is reported as CAN TIGHTEN and never rewrites the mark: a plain run never writes its own bar.
function Get-TcSitewideRatchetVerdict { param([hashtable]$Measured, $Ratchet)
  $find = New-Object System.Collections.Generic.List[string]
  $tight = New-Object System.Collections.Generic.List[string]
  $base = @{}
  if ($Ratchet -and $Ratchet.pages) { foreach ($p in $Ratchet.pages.PSObject.Properties) { $base[$p.Name] = $p.Value } }
  foreach ($s in @($Measured.Keys | Sort-Object)) {
    $m = $Measured[$s]
    if (-not $base.ContainsKey($s)) { $find.Add(("NEW      {0}: {1} literal(s){2} on a page that had none when the mark was set" -f $s, $m.literals, $(if ($m.title) { ' and a price in the TITLE' } else { '' }))); continue }
    $b = $base[$s]
    if ([int]$m.literals -gt [int]$b.literals) { $find.Add(("GREW     {0}: {1} literal(s), mark {2}" -f $s, $m.literals, $b.literals)) }
    elseif ([int]$m.literals -lt [int]$b.literals) { $tight.Add(("{0}: {1} literal(s), mark {2}" -f $s, $m.literals, $b.literals)) }
    if ($m.title -and -not [bool]$b.title) { $find.Add(("TITLE    {0}: a price in the title, mark had none" -f $s)) }
    elseif ((-not $m.title) -and [bool]$b.title) { $tight.Add(("{0}: title no longer carries a price" -f $s)) }
  }
  foreach ($s in @($base.Keys | Sort-Object)) { if (-not $Measured.ContainsKey($s)) { $tight.Add(("{0}: clean (mark {1} literal(s){2})" -f $s, $base[$s].literals, $(if ([bool]$base[$s].title) { ', title' } else { '' }))) } }
  $max = if ($Ratchet -and $null -ne $Ratchet.pages_max) { [int]$Ratchet.pages_max } else { 0 }
  if ($Measured.Count -gt $max) { $find.Add(("COUNT    {0} page(s) state a grocery price, mark {1}" -f $Measured.Count, $max)) }
  elseif ($Measured.Count -lt $max) { $tight.Add(("pages {0}, mark {1}" -f $Measured.Count, $max)) }
  return @{ findings = $find.ToArray(); tighten = $tight.ToArray() }
}
