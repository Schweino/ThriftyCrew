<#
  audit-search-links.ps1 - reachability probe for the per-store "Find at store" SEARCH templates.

  THE BUG CLASS THIS CATCHES: a link that EXISTS but does not RESOLVE. Every other link guard in this
  estate asks whether a chip has an href (the all-3 rule at build-deals-page.ps1:2134 counts them) or
  whether a PRODUCT url still points at the right product (audit-links, audit-everyday-mismatch). None of
  them ever fetches a SEARCH url, so a store can quietly re-route its storefront and the fallback link -
  the one Brad's every-price-has-a-link rule leans on - 404s for everyone, indefinitely, silently.

  FOUNDING BUG (2026-08-02): 'Family Fare' = 'https://www.shopfamilyfare.com/search?search_term={q}'
  returned "Page not found - Family Fare". It was shipping to real shoppers on 20 chips in the live
  public/board.json feed, and nothing in the estate could see it. (It read as latent because a scan of
  out\deals-page.html found zero hits - the chips do not live in the post, they are injected client-side
  from board.json, so the page HTML is the wrong artifact to scan.) Real URL:
  https://www.shopfamilyfare.com/shop#!/?q={q}&search_option_id=product

  WHY STATUS CODES ARE NOT ENOUGH, AND WHY THE FRAGMENT IS STRIPPED
  Family Fare's storefront is a Freshop SPA, so EVERY /shop/* path returns 200 from the SPA shell - a
  status code alone can never distinguish a live route from a dead one there. And the SPA routes off the
  hash-bang, which the server never sees. So this probe requests only the SERVER-VISIBLE part of the url
  (everything before '#') and judges THAT. That is exactly the part the founding bug got wrong: the old
  template's server path was /search?search_term=milk -> 404, the new one's is /shop -> 200. What this
  probe proves for a fragment-routed store is that the SHELL resolves, not that results render; the report
  labels those cells 'shell' so nobody reads more into a pass than it earned.

  THE THREE-VALUED RESULT. A probe that can only say OK/BROKEN reports "clean" when it is really blind,
  which is the gates-that-can-never-arm failure mode. Every store lands in one of:
    OK          reachable, and not a not-found page
    BROKEN      4xx/5xx, or a <title> that says not-found (this is a finding; exit 2)
    UNPROVABLE  connect failure / 403 / 429 / 503 - the bot wall answered, not the store
  If EVERY store is UNPROVABLE the script exits 3 (could-not-evaluate) rather than 0. Silence from a
  blocked probe is not a clean board.

  MEASURED COVERAGE, NOT ASSUMED (2026-08-02, from this machine): Walmart, Hy-Vee, Aldi, Fareway, Sam's
  Club and Family Fare all answer a headless GET; Baker's (Kroger) refuses the connection outright and is
  UNPROVABLE from here every run. So this probe covers 6 of 7 templates. That is a real hole and it is
  named in the report rather than papered over - Baker's template has to be re-checked by hand.

  NOT-FOUND DETECTION IS <title>-SCOPED ON PURPOSE. Matching not-found wording against the whole body
  false-positived on all 6 reachable stores in testing (the words appear in inline scripts and nav copy).
  Scoped to the <title> it fired on exactly one thing: the founding bug's "Page not found - Family Fare".
  Same reason the bot-wall test is status-only and never a body regex for 'robot'/'access denied'.

  SECOND SIGNAL - THE QUERY ECHO. A template can rot WITHOUT 404ing: rename the parameter (?q= -> ?query=)
  and the store serves a generic 200 that ignores our query entirely. Four stores echo the query back in
  their <title> ("milk - Walmart.com", "ALDI Milk Delivery..."), which proves the search actually RECEIVED
  it. That tier is recorded per store and a DOWNGRADE from the accepted baseline is reported. Advisory
  only, and deliberately so: a store is free to change its title format, and paging Brad over marketing
  copy is how a guard teaches people to ignore it. Re-accept with -Accept after checking by hand.

  WHAT THIS CANNOT PROVE, and the manual procedure: that the url is the one the store's own search box
  emits. Nothing headless can. When a store IS found broken, get the real url the way the founding bug was
  fixed - open the storefront, type a commodity into its own nav search box, and read the resulting url -
  rather than guessing paths, because on an SPA every guessed path returns 200.

  SINGLE SOURCE. The templates are EXTRACTED from build-deals-page.ps1's $SEARCHURLS block, never copied
  here. A second copy is the two-copies-of-the-same-math failure: the copy would keep passing after the
  real one rotted. Extraction failing, or yielding fewer entries than stores.json has stores, is itself a
  finding - it fails closed.

  Usage:  audit-search-links.ps1 [-Alert] [-Accept] [-Query milk] [-TimeoutSec 25]
  Offline/fixture:  -TemplatesFile <json>  -ResponsesFile <json>  -ReportDir <dir>
    With -ResponsesFile the probe makes NO network calls and reads canned {status,title} per url, so
    test-auditors can replay the founding bug deterministically. -ReportDir keeps a fixture run from
    overwriting the live report (the audit-basis-reconcile lesson).
  Exit: 0 = every provable template resolves, 2 = a finding, 3 = could not evaluate (all UNPROVABLE).
#>
param(
  [switch]$Alert,
  [switch]$Accept,
  [string]$Query = 'milk',
  [int]$TimeoutSec = 25,
  [string]$OutDir,
  [string]$ReportDir,
  [string]$TemplatesFile,
  [string]$ResponsesFile,
  [string]$BaselineFile
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir)    { $OutDir    = Join-Path $root 'out' }
if (-not $ReportDir) { $ReportDir = $OutDir }
$issues = New-Object System.Collections.Generic.List[string]
$notes  = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- templates (extracted, never copied)
function Get-SearchTemplates {
  param([string]$SourceFile)
  $lines = [IO.File]::ReadAllLines($SourceFile)
  $start = -1
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\$SEARCHURLS\s*=\s*@\{') { $start = $i; break } }
  if ($start -lt 0) { return $null }
  # Walk to the closing brace by depth so a future nested hashtable cannot truncate the block silently.
  $depth = 0; $block = New-Object System.Collections.Generic.List[string]
  for ($i = $start; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    $block.Add($ln)
    $depth += ([regex]::Matches($ln, '\{')).Count
    $depth -= ([regex]::Matches($ln, '\}')).Count
    if ($depth -le 0 -and $i -gt $start) { break }
    if ($depth -le 0 -and $i -eq $start -and $ln -match '\}') { break }
  }
  if ($depth -gt 0) { return $null }
  # Evaluate the block as an EXPRESSION, not as the assignment it is in source. Invoke-Expression on
  # '$SEARCHURLS = @{...}' performs the assignment and emits nothing, so the first cut extracted the block
  # correctly and then returned $null - and the fail-closed branch fired on a perfectly healthy file. Naming
  # the variable after the assignment is what makes the hashtable the value of the expression.
  try {
    $val = Invoke-Expression ((($block -join "`n")) + "`n" + '$SEARCHURLS')
    if ($val -isnot [hashtable] -or $val.Count -eq 0) { return $null }
    $out = @{}
    foreach ($k in $val.Keys) { if ([string]$k -notmatch '^_') { $out[[string]$k] = [string]$val[$k] } }
    return $out
  } catch { return $null }
}

if ($TemplatesFile) {
  $tj = Get-Content $TemplatesFile -Raw | ConvertFrom-Json
  $templates = @{}
  # '_'-prefixed keys are fixture prose, not stores. Without this the fixtures' own _readme was probed as a
  # store, reported UNPROVABLE, and then failed the registry cross-check as an unregistered store - noise
  # that made the clean twin exit 2. Caught by running the fixtures, which is the entire point of them.
  foreach ($p in $tj.PSObject.Properties) { if ([string]$p.Name -notmatch '^_') { $templates[[string]$p.Name] = [string]$p.Value } }
} else {
  $src = Join-Path $root 'build-deals-page.ps1'
  $templates = Get-SearchTemplates -SourceFile $src
  if ($null -eq $templates) {
    Write-Output 'search-links: COULD NOT EVALUATE - the $SEARCHURLS block could not be extracted from build-deals-page.ps1.'
    Write-Output '  Nothing was probed. This is fail-closed on purpose: an extraction that silently returned nothing would'
    Write-Output '  report every template healthy. Check that the block still starts with "$SEARCHURLS = @{" on its own line.'
    exit 3
  }
}

# registry cross-check: a store with no template ships chips with no fallback link at all
$regStores = @()
try { $regStores = @((Get-Content (Join-Path $root 'stores.json') -Raw | ConvertFrom-Json).stores | ForEach-Object { [string]$_.name }) } catch {}
$walled = @{}
try { foreach ($s in (Get-Content (Join-Path $root 'stores.json') -Raw | ConvertFrom-Json).stores) { $walled[[string]$s.name] = [bool]$s.walled } } catch {}
if ($regStores.Count -gt 0) {
  foreach ($s in $regStores) { if (-not $templates.ContainsKey($s)) { $issues.Add("registry: '$s' is in stores.json but has NO search template - its unlinked chips get no fallback link at all") } }
  foreach ($k in $templates.Keys) { if ($regStores -notcontains $k) { $issues.Add("registry: search template '$k' is not a registered store in stores.json") } }
  if ($templates.Count -lt $regStores.Count) { $issues.Add("extraction: found only " + $templates.Count + " template(s) for " + $regStores.Count + " registered store(s) - the extraction may have truncated") }
}

# ---------------------------------------------------------------- the query: a REAL commodity, or say so
# THE PROBE NEVER REWRITES ITS OWN QUERY. The first cut swapped in a board commodity whenever the requested
# term was not an exact commodity label, which (a) made every canned-response lookup miss, so the must-fire
# fixture reported BLIND instead of firing - the guard was structurally incapable of catching its own
# founding bug - and (b) is the same laundering shape as a builder stamping its own as_of: the report would
# name one term while the probe measured another. It only NOTES what it found, and the term probed is
# recorded in the report.
$boardTerms = @()
try {
  $cmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -EA SilentlyContinue | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if ($cmpF) { $boardTerms = @((Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).comparison | ForEach-Object { [string]$_.commodity }) }
} catch {}
if ($boardTerms.Count -gt 0) {
  $hit = @($boardTerms | Where-Object { $_ -imatch [regex]::Escape($Query) })
  if ($hit.Count -gt 0) { $notes.Add("probing with '" + $Query + "' (a real board commodity term - matches " + $hit.Count + " commodit(y/ies), e.g. '" + $hit[0] + "')") }
  else { $notes.Add("probing with '" + $Query + "', which matches NO commodity on the newest board - a store returning nothing for it would be honest, so prefer a term the board actually carries") }
}

# ---------------------------------------------------------------- fetch layer
$canned = $null
if ($ResponsesFile) {
  $canned = @{}
  $rj = Get-Content $ResponsesFile -Raw | ConvertFrom-Json
  foreach ($p in $rj.PSObject.Properties) { $canned[[string]$p.Name] = $p.Value }
}
$client = $null
if (-not $canned) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Add-Type -AssemblyName System.Net.Http
  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  # A default .NET user-agent is refused by more storefronts than a browser one is, and a probe that is
  # blocked everywhere proves nothing. This reads, it never buys, and it fires once a week per store.
  $client.DefaultRequestHeaders.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36')
  $client.DefaultRequestHeaders.Add('Accept', 'text/html,application/xhtml+xml')
}
function Fetch([string]$url) {
  if ($canned) {
    if ($canned.ContainsKey($url)) { $c = $canned[$url]; return [pscustomobject]@{ status = [int]$c.status; title = [string]$c.title } }
    return [pscustomobject]@{ status = 0; title = '' }     # unlisted in the fixture = connect failure
  }
  try {
    $r = $client.GetAsync($url).Result
    $body = ''
    try { $body = $r.Content.ReadAsStringAsync().Result } catch {}
    $title = ''
    $m = [regex]::Match($body, '(?is)<title[^>]*>(.*?)</title>')
    if ($m.Success) { $title = (($m.Groups[1].Value -replace '\s+', ' ').Trim()) }
    return [pscustomobject]@{ status = [int]$r.StatusCode; title = $title }
  } catch { return [pscustomobject]@{ status = 0; title = '' } }
}

# ---------------------------------------------------------------- probe
$rows = New-Object System.Collections.Generic.List[object]
foreach ($store in @($templates.Keys | Sort-Object)) {
  $tpl = [string]$templates[$store]
  $full = $tpl.Replace('{q}', [uri]::EscapeDataString($Query))
  # strip the fragment: the server never sees it, so judging it would judge nothing
  $hash = $full.IndexOf('#')
  $serverUrl = if ($hash -ge 0) { $full.Substring(0, $hash) } else { $full }
  $routing = if ($hash -ge 0) { 'shell' } else { 'path' }
  $res = Fetch $serverUrl
  $st = [int]$res.status
  $title = [string]$res.title
  $notFound = ($title -imatch 'page not found|not found|page cannot be found|404')
  $verdict = ''
  if ($st -eq 0 -or $st -eq 403 -or $st -eq 429 -or $st -eq 503) { $verdict = 'UNPROVABLE' }
  elseif ($st -ge 400 -or $notFound) { $verdict = 'BROKEN' }
  else { $verdict = 'OK' }
  # echo tier: did the store's own title repeat our query back? (proves the query was READ, not just that
  # a page exists). Only meaningful on an OK row.
  $echo = $false
  if ($verdict -eq 'OK' -and $title) { $echo = ($title -imatch [regex]::Escape($Query)) }
  $rows.Add([pscustomobject]@{ store = $store; url = $serverUrl; routing = $routing; status = $st; title = $title; verdict = $verdict; echo = $echo })
  if ($verdict -eq 'BROKEN') {
    $why = if ($notFound -and $st -lt 400) { "HTTP $st but the page title says not-found: '" + $title + "'" } else { "HTTP $st" }
    $issues.Add("$store search template does not resolve ($why) - $serverUrl")
  }
}

# ---------------------------------------------------------------- echo-tier baseline (advisory)
# -BaselineFile exists so this branch has a reachable self-test. Pointed at the live file by default, the
# downgrade path could only ever be exercised by waiting for a real store to change its title - i.e. never,
# which is how a branch ships unproven and is discovered wrong years later.
$baseF = if ($BaselineFile) { $BaselineFile } else { Join-Path $root 'search-link-baseline.json' }
$base = @{}
if (Test-Path $baseF) {
  try { $bj = Get-Content $baseF -Raw | ConvertFrom-Json; foreach ($p in $bj.stores.PSObject.Properties) { $base[[string]$p.Name] = [bool]$p.Value.echo } } catch {}
}
$downgrades = @()
foreach ($r in $rows) {
  if ($r.verdict -ne 'OK') { continue }
  if ($base.ContainsKey($r.store) -and $base[$r.store] -and -not $r.echo) {
    $downgrades += ($r.store + " stopped echoing the query in its page title - the parameter name may have changed (the 200-but-ignores-our-query rot). Verify by hand: open the storefront, type '" + $Query + "' into its own search box, and compare the url it produces.")
  }
}

$provable = @($rows | Where-Object { $_.verdict -ne 'UNPROVABLE' })
$unprov   = @($rows | Where-Object { $_.verdict -eq 'UNPROVABLE' })

if ($Accept) {
  $acc = [ordered]@{}
  foreach ($r in ($rows | Sort-Object store)) { $acc[$r.store] = [ordered]@{ echo = [bool]$r.echo; verdict = [string]$r.verdict; accepted = (Get-Date -Format 'yyyy-MM-dd') } }
  ([ordered]@{ readme = 'Accepted per-store echo tier for audit-search-links.ps1. echo=true means that store repeats the query in its page <title>, which proves the search READ our query parameter. A drop from true to false is reported as an advisory downgrade, never a hard finding - re-accept here after checking the store by hand.'; query = $Query; stores = $acc } | ConvertTo-Json -Depth 6) | Set-Content $baseF -Encoding UTF8
  Write-Output ("search-links: baseline accepted for " + $rows.Count + " store(s) -> search-link-baseline.json")
}

# ---------------------------------------------------------------- report
$reportF = Join-Path $ReportDir 'search-links-report.json'
try {
  ([ordered]@{
    generated  = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    query      = $Query
    offline    = [bool]$canned
    checked    = $rows.Count
    provable   = $provable.Count
    unprovable = @($unprov | ForEach-Object { $_.store })
    issues     = @($issues)
    downgrades = @($downgrades)
    rows       = @($rows)
  } | ConvertTo-Json -Depth 6) | Set-Content $reportF -Encoding UTF8
} catch {}

foreach ($n in $notes) { Write-Output ("  note: " + $n) }
foreach ($r in ($rows | Sort-Object store)) {
  $tier = if ($r.verdict -eq 'OK') { if ($r.echo) { 'OK (query echoed)' } elseif ($r.routing -eq 'shell') { 'OK (shell resolves; SPA renders results client-side)' } else { 'OK' } } else { $r.verdict }
  Write-Output ("  {0,-12} {1,4}  {2}" -f $r.store, $r.status, $tier)
}
foreach ($u in $unprov) {
  $w = if ($walled.ContainsKey($u.store) -and $walled[$u.store]) { ' (walled store - a bot wall answering is expected here)' } else { '' }
  Write-Output ("  UNPROVABLE  " + $u.store + $w + " - its template was NOT checked this run; re-verify by hand")
}
foreach ($d in $downgrades) { Write-Output ("  DOWNGRADE   " + $d) }

if ($provable.Count -eq 0) {
  Write-Output 'search-links: COULD NOT EVALUATE - every store was UNPROVABLE (bot wall or no network). No template was checked; this is NOT a clean result.'
  exit 3
}
if ($issues.Count -eq 0) {
  Write-Output ("search-links: OK  " + $provable.Count + " of " + $rows.Count + " template(s) resolve for '" + $Query + "'" + $(if ($unprov.Count -gt 0) { "; " + $unprov.Count + " unprovable (listed above)" } else { '' }))
  exit 0
}

Write-Output ("search-links: " + $issues.Count + " finding(s):")
$issues | ForEach-Object { Write-Output ("  " + $_) }
Write-Output '  A broken template means every chip that falls back to it sends a shopper to a dead page.'
Write-Output "  Get the real url from the store's OWN search box (type a commodity into it and read the url) -"
Write-Output '  do not guess paths: on an SPA storefront every guessed path returns 200.'
if ($Alert) {
  $sig  = (($issues | Sort-Object) -join ';')
  $sigF = Join-Path $OutDir 'search-links-alert.sig'
  $prev = if (Test-Path $sigF) { (Get-Content $sigF -Raw).Trim() } else { '' }
  $sigH = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($sig))) -replace '-',''
  if ($sigH -ne $prev) {
    try {
      & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject ("Grocery: a store SEARCH link is dead - " + $issues.Count + " template(s)") -Body ("audit-search-links.ps1 fetched each store's 'Find at store' search template. Broken: " + (($issues | Select-Object -First 8) -join ' | ') + ".`n`nEvery chip that falls back to that template is sending a shopper to a dead page (the 2026-08-02 Family Fare class, which shipped on 20 live chips). Fix the template in build-deals-page.ps1 `$SEARCHURLS, then rebuild - the chips live in public/board.json, not in the post html.`n`nGet the real url from the store's OWN nav search box; do not guess paths, because on an SPA storefront every guessed path returns 200. Report: " + $reportF) | Out-Null
      if ($LASTEXITCODE -eq 0) { Set-Content $sigF -Value $sigH -Encoding ASCII }
    } catch {}
  }
}
exit 2
