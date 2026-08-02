<#
  retrofit-source-credit.ps1 - give the original 113 recipes the source credit every other card carries.

  THE GAP (found 2026-08-02 from a reader's question about one card, open since the R100 expansion as
  "#124 credit retrofit"). Every r100 and r300 card renders a gold SOURCE callout at the top of the body:

      Recipe adapted from <a ...>beyondkimchee.com</a>, rebuilt for 14-serving budget meal prep with
      weighed portions and Omaha pricing.

  The 113 ORIGINAL recipes render nothing, because their specs carry `source_site`, `source_url` and
  `credit_html` all empty. It is not that we never knew where they came from - `recipes-db.json` has the
  site and the URL for 100 of the 113 and always did. The fields simply never got copied into the spec
  when the originals were reconstructed for the 2026-07-26 cost redesign, and build-card2 reads the spec.
  So a recipe adapted from Food Faith Fitness has been publishing with no attribution at all.

  WHAT THIS DOES: for a spec with NO credit, copy source_site + source_url from recipes-db and build
  credit_html in the SAME sentence the other 399 use (the 400th is the redesign's pilot card, which has no
  `servings` field at all and phrases it without the serving count - an artefact, not a second standard).

  WHAT IT REFUSES, each one a way a retrofit like this quietly does damage:
   1. A SPEC THAT ALREADY HAS A CREDIT. Never overwritten. A retrofit that can edit existing attribution
      is a retrofit that can silently re-attribute a recipe to the wrong site.
   2. NO SOURCE IN recipes-db. 13 of the 113 have none recorded anywhere. Inventing one, or writing a
      half-credit naming a site with no link, is worse than the honest silence they have now. Named and
      skipped.
   3. A URL THAT IS NOT http(s). It goes straight into an href; anything else ships a broken or unsafe
      link on 100 pages at once.
   4. A SITE NAME THAT NEEDS ESCAPING is escaped, not refused - it becomes link TEXT, and an unescaped
      ampersand in a site name is how you get a card that fails validation.

  Read-only unless -Apply. Every change and every refusal is printed.
  Usage: .\retrofit-source-credit.ps1 [-Apply]   |   .\retrofit-source-credit.ps1 -SelfTest
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }

function ConvertTo-HtmlText([string]$s) {
  return (([string]$s) -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

function New-CreditHtml([string]$site, [string]$url, $servings) {
  # The 399-card sentence, verbatim. The serving count is read from the spec rather than hardcoded so a
  # recipe that is not 14 servings cannot be handed a sentence that says it is.
  $n = 0
  [void][int]::TryParse(([string]$servings), [ref]$n)
  $scale = if ($n -gt 0) { "$n-serving " } else { '' }
  $u = ConvertTo-HtmlText $url
  $s = ConvertTo-HtmlText $site
  return ("Recipe adapted from <a href=`"$u`" target=`"_blank`" rel=`"noopener`">$s</a>, " +
          "rebuilt for ${scale}budget meal prep with weighed portions and Omaha pricing.")
}

function Invoke-Retrofit($specDir, $dbPath, [bool]$apply) {
  $db = Get-Content $dbPath -Raw | ConvertFrom-Json
  $bySlug = @{}
  foreach ($r in @($db.recipes)) { $bySlug[[string]$r.slug] = $r }

  $done = New-Object System.Collections.Generic.List[string]
  $skipHave = 0
  $noSource = New-Object System.Collections.Generic.List[string]
  $badUrl = New-Object System.Collections.Generic.List[string]
  foreach ($f in @(Get-ChildItem (Join-Path $specDir '*.json') | Where-Object { $_.Name -ne '_index.json' })) {
    $slug = $f.BaseName
    $spec = $null
    try { $spec = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if ([string]$spec.credit_html) { $skipHave++; continue }          # refusal 1
    $r = $bySlug[$slug]
    $site = if ($r) { [string]$r.source_site } else { '' }
    $url = if ($r) { [string]$r.source_url } else { '' }
    if (-not $site -or -not $url) { $noSource.Add($slug); continue }  # refusal 2
    if ($url -notmatch '^https?://') { $badUrl.Add("$slug ($url)"); continue }   # refusal 3
    # The serving count comes from the spec, and falls back to the DB ROW the source itself came from.
    # The fallback is not decoration: NONE of the 113 original specs carries a `servings` field (the
    # reconstruction never wrote one), while recipes-db says 14 for all 513 - so without it, all 100
    # retrofitted credits would read "rebuilt for budget meal prep" while the 399 originals-of-record say
    # "rebuilt for 14-serving budget meal prep", a second sentence template minted by accident.
    $svc = $spec.servings
    $svcN = 0; [void][int]::TryParse(([string]$svc), [ref]$svcN)
    if ($svcN -le 0 -and $r) { $svc = $r.servings }
    $credit = New-CreditHtml $site $url $svc
    if ($spec.PSObject.Properties.Name -contains 'source_site') { $spec.source_site = $site } else { $spec | Add-Member -NotePropertyName source_site -NotePropertyValue $site }
    if ($spec.PSObject.Properties.Name -contains 'source_url') { $spec.source_url = $url } else { $spec | Add-Member -NotePropertyName source_url -NotePropertyValue $url }
    if ($spec.PSObject.Properties.Name -contains 'credit_html') { $spec.credit_html = $credit } else { $spec | Add-Member -NotePropertyName credit_html -NotePropertyValue $credit }
    $done.Add($slug)
    if ($apply) { $spec | ConvertTo-Json -Depth 8 | Set-Content $f.FullName -Encoding UTF8 }
  }
  return @{ done = @($done.ToArray()); already = $skipHave; noSource = @($noSource.ToArray()); badUrl = @($badUrl.ToArray()) }
}

if ($SelfTest) {
  $fail = 0
  function Chk([string]$label, [bool]$cond, [string]$got) {
    if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
  }
  $T = Join-Path $env:TEMP ('credit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path (Join-Path $T 'recipes') -Force | Out-Null
  try {
    # FROZEN FIXTURE - the live case that started this, plus one of each refusal.
    @{ name = 'General Tso'; servings = 14; credit_html = ''; source_site = ''; source_url = '' } |
      ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T 'recipes\slow-cooker-general-tso-chicken-bowls.json') -Encoding UTF8
    @{ name = 'Already Credited'; servings = 14; credit_html = 'Recipe adapted from <a href="https://keep.me">keep.me</a>.' } |
      ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T 'recipes\already.json') -Encoding UTF8
    @{ name = 'No Source Anywhere'; servings = 14; credit_html = '' } |
      ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T 'recipes\bbq-chicken-rice-bowls.json') -Encoding UTF8
    @{ name = 'Bad Url'; servings = 14; credit_html = '' } |
      ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T 'recipes\badurl.json') -Encoding UTF8
    @{ name = 'Ampersand Site'; servings = 14; credit_html = '' } |
      ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T 'recipes\amp.json') -Encoding UTF8
    @{ recipes = @(
      @{ slug = 'slow-cooker-general-tso-chicken-bowls'; source_site = 'Food Faith Fitness'; source_url = 'https://www.foodfaithfitness.com/slow-cooker-general-tsos-chicken/' },
      @{ slug = 'already'; source_site = 'Other Site'; source_url = 'https://other.example/' },
      @{ slug = 'bbq-chicken-rice-bowls'; source_site = ''; source_url = '' },
      @{ slug = 'badurl'; source_site = 'Broken'; source_url = 'javascript:alert(1)' },
      @{ slug = 'amp'; source_site = 'Salt & Lavender'; source_url = 'https://saltandlavender.example/' }
    ) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T 'recipes-db.json') -Encoding UTF8

    $r = Invoke-Retrofit (Join-Path $T 'recipes') (Join-Path $T 'recipes-db.json') $true
    $g = Get-Content (Join-Path $T 'recipes\slow-cooker-general-tso-chicken-bowls.json') -Raw | ConvertFrom-Json
    Chk 'MUST FIRE  the live case gets the 399-card sentence, verbatim' ($g.credit_html -eq 'Recipe adapted from <a href="https://www.foodfaithfitness.com/slow-cooker-general-tsos-chicken/" target="_blank" rel="noopener">Food Faith Fitness</a>, rebuilt for 14-serving budget meal prep with weighed portions and Omaha pricing.') ("" + $g.credit_html)
    Chk 'MUST FIRE  source_site and source_url land on the spec too' ($g.source_site -eq 'Food Faith Fitness' -and $g.source_url -match 'foodfaithfitness') ("$($g.source_site) / $($g.source_url)")
    $a = Get-Content (Join-Path $T 'recipes\already.json') -Raw | ConvertFrom-Json
    Chk 'MUST NOT FIRE  an existing credit is never re-attributed' ($a.credit_html -match 'keep\.me' -and $a.credit_html -notmatch 'other') ("" + $a.credit_html)
    $b = Get-Content (Join-Path $T 'recipes\bbq-chicken-rice-bowls.json') -Raw | ConvertFrom-Json
    Chk 'MUST NOT FIRE  no source recorded -> left silent, and NAMED' ((-not [string]$b.credit_html) -and ($r.noSource -contains 'bbq-chicken-rice-bowls')) ("credit=[$($b.credit_html)] named=$($r.noSource -join ',')")
    $u = Get-Content (Join-Path $T 'recipes\badurl.json') -Raw | ConvertFrom-Json
    Chk 'MUST NOT FIRE  a non-http URL never reaches an href' ((-not [string]$u.credit_html) -and (@($r.badUrl | Where-Object { $_ -match 'badurl' }).Count -eq 1)) ("credit=[$($u.credit_html)]")
    $m = Get-Content (Join-Path $T 'recipes\amp.json') -Raw | ConvertFrom-Json
    Chk 'an ampersand in the site name is ESCAPED, not refused' ($m.credit_html -match 'Salt &amp; Lavender') ("" + $m.credit_html)
    $r2 = Invoke-Retrofit (Join-Path $T 'recipes') (Join-Path $T 'recipes-db.json') $true
    Chk 'idempotent - a second run credits nothing new' ($r2.done.Count -eq 0) ("done=" + $r2.done.Count)
    # THE SERVINGS FALLBACK, both directions. None of the 113 original specs carries a `servings` field,
    # so the DB row's count must fill in (live case: all 100 credits would otherwise mint a second
    # sentence template). And when NEITHER side knows, the sentence must not invent a number.
    @{ name = 'Db Servings'; credit_html = '' } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T 'recipes\dbserv.json') -Encoding UTF8
    @{ name = 'No Servings'; credit_html = '' } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T 'recipes\noserv.json') -Encoding UTF8
    $dbp = Join-Path $T 'recipes-db.json'
    $d2 = Get-Content $dbp -Raw | ConvertFrom-Json
    $d2.recipes += @{ slug = 'dbserv'; source_site = 'S'; source_url = 'https://s.example/'; servings = 14 }
    $d2.recipes += @{ slug = 'noserv'; source_site = 'S'; source_url = 'https://s.example/' }
    $d2 | ConvertTo-Json -Depth 5 | Set-Content $dbp -Encoding UTF8
    $null = Invoke-Retrofit (Join-Path $T 'recipes') $dbp $true
    $ds = Get-Content (Join-Path $T 'recipes\dbserv.json') -Raw | ConvertFrom-Json
    Chk 'MUST FIRE  a spec with no servings takes the DB row''s count (the 100-original case)' ($ds.credit_html -match 'rebuilt for 14-serving budget') ("" + $ds.credit_html)
    $ns = Get-Content (Join-Path $T 'recipes\noserv.json') -Raw | ConvertFrom-Json
    Chk 'a recipe NEITHER side has a count for is not told it has one' ($ns.credit_html -match 'rebuilt for budget meal prep') ("" + $ns.credit_html)
  } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$res = Invoke-Retrofit (Join-Path $mp 'db\recipes') (Join-Path $mp 'recipes-db.json') ([bool]$Apply)
Write-Output ("source-credit retrofit: {0} recipe(s) credited, {1} already had one{2}" -f $res.done.Count, $res.already, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))
if ($res.noSource.Count) {
  Write-Output ("  NO SOURCE RECORDED ANYWHERE ({0}) - left silent on purpose; a half-credit naming a site with no link is worse than none:" -f $res.noSource.Count)
  foreach ($s in $res.noSource) { Write-Output ("    " + $s) }
}
if ($res.badUrl.Count) {
  Write-Output ("  UNUSABLE URL ({0}) - would have shipped a broken or unsafe href:" -f $res.badUrl.Count)
  foreach ($s in $res.badUrl) { Write-Output ("    " + $s) }
}
if ($Apply -and $res.done.Count) {
  ($res.done -join "`n") | Set-Content (Join-Path $mp 'out\credit-retrofit-slugs.txt') -Encoding UTF8
  Write-Output '  slug list -> out\credit-retrofit-slugs.txt (rebuild + republish these cards)'
}
exit 0
