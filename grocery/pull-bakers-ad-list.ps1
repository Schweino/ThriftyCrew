<#
  pull-bakers-ad-list.ps1 - Baker's weekly ad, read from the ad's OWN text feed and routed onto the Baker's search
  terms the Kroger API lane asks. design\PLAN-bakers-weekly-ad-feed-2026-09-18.md (Brad approved plan and build,
  2026-09-18).

  WHY. The Kroger API lane (pull-regular-bakers-api.ps1) asks 7 of ~600 terms a day. It prices a sale correctly
  when it asks, but it cannot DISCOVER what newly went on sale. The only discovery path was a vision read of the
  printed flyer by a Wednesday Chrome agent that was retired on 2026-08-22; it landed by hand in 5 of 8 ad weeks
  since, and the week of 09-09 it alone supplied 17 Baker's sale cells and 3 crowns (clementines, coffee-pods,
  pasta-sauce). The old ad needs nothing: every stored promo row carries its own ad_to and compare-deals refuses
  an expired one. So we read what the NEW ad puts on sale and ask exactly those terms.

  THE SOURCE (headless, no key, no cookie):
    GET https://oms-kroger-webapp-da-classic-api-prod.przone.net/api/dacs/<adId>?location=<loc>
        -> adId, weekNumber, startDate, endDate, circularType, pages[] (eventPageId, page)
    GET .../api/dacs/<adId>/pages/<eventPageId>?location=<loc>
        -> contents[]; each contentType 'Offer' has a mapConfig JSON STRING whose content holds id, headline,
           bodyCopy and stores (itself a JSON string: [{locationNumbers: "615...,61500319,..."}]).
  PRICES ARE NOT IN IT (2 of 169 bodies carry a '$' on 2026-09-16). It is the LIST; the Kroger product API supplies
  every price, exactly as it does for every other Baker's row. Nothing here writes a price, so nothing here can
  fabricate one.

  WHERE THE AD ID COMES FROM, in this order, and EVERY candidate is verified against the ad's own dates:
    1. -AdId <guid>                         a person recovering a missed week by hand
    2. out\bakers\bakers-ad-id-<start>.json  an id this script already verified, whose window contains today
    3. out\bakers\bakers-ad-id-seen-<date>.json (or -SeenFile) - the /api/dacs/<guid> URLs the weekly-ad page itself
       requested, read by the 08:00 capture's real Chrome (pull-browser-stores.py --bakers-ad-id-out). The id is a
       GUID that changes weekly, and bakersplus.com is Akamai-walled to a server-side fetch, so this is the ONE
       browser-dependent input: one page load a week, no vision.
  To recover by hand: open https://www.bakersplus.com/weeklyad on the Saddlecreek store, read the /api/dacs/<guid>
  request (DevTools Network, or performance.getEntriesByType('resource')), then run this with -AdId <guid>.

  ROUTING USES THE ENGINE'S MATCHER, NOT WORD MATCHING. Naive phrase matching linked only 41 of 169 offers to a
  Baker's term. Each offer's text is split into candidate product phrases (the headline, the whole text, and every
  ';' then ' or ' fragment, because the body carries the second product: "Velveeta Shells & Cheese" | "9.4-12 oz or
  Classico Pasta Sauce, 15-24 oz; Select Varieties"), each phrase goes through match-lib's Resolve-Commodity over
  commodities.json and the global exclude list (what compare-deals runs), and every commodity maps to ALL its
  Baker's search terms in commodity-search.json. OVER-ROUTING COSTS A REQUEST; UNDER-ROUTING COSTS A SALE CELL. An
  extra term can never put a wrong price on the board, because the API rows it returns are matched by the same
  engine at compare time; a missed term leaves that week's sale unpriced. So every phrase is routed and the union
  is kept. Unrouted offers (alcohol, flowers, candles, goods the board does not track) are written to the file's
  unrouted[] with the phrases tried - evidence, never silently dropped.

  WHAT IT WRITES (only after every check passed; a refusal writes nothing):
    out\bakers\bakers-ad-id-<start>.json    {ad_id, location, week_number, ad_from, ad_to, captured, source, source_url}
    out\bakers\bakers-ad-list-<start>.json  {ad_id, week_number, ad_from, ad_to, offer_count, routed_count,
                                             unrouted_count, term_count, terms[{id,term}], offers[], unrouted[]}
  capture-policy-lib's Get-BakersAdOwed turns terms[] into the API lane's owed ad_terms.

  REFUSES, LOUDLY, AND NEVER GUESSES: no ad id (exit 4); an ad whose own adId is not the one asked for, whose
  window does not contain today, whose root or ANY page cannot be fetched or parsed, or that lists 0 offers for
  the location (exit 1). A partial list is worse than none: the missing pages' sales would simply never be asked.

  EXIT CODES  0 list written, or a current list already on disk (-Force re-pulls)   1 refused   4 no ad id
  Self-test:  pull-bakers-ad-list.ps1 -SelfTest   (hermetic: the frozen 2026-09-16 ad in
              regression-inputs\bakers-ad-2026-09-16, a temp out dir, no network)
#>
[CmdletBinding()]
param(
  [string]$AdId = '',
  [string]$Location = '61500319',        # Baker's - Saddlecreek, 888 S Saddle Creek Rd, Omaha 68106
  [string]$OutDir = '',
  [string]$Today = '',
  # Read root.json and pages\<eventPageId>.json from this folder instead of the network (the self-test).
  [string]$FixtureDir = '',
  [string]$SeenFile = '',
  [switch]$Force,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:DacsBase = 'https://oms-kroger-webapp-da-classic-api-prod.przone.net/api/dacs'
$script:GuidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

# ============================================================================ SELF-TEST
if ($SelfTest) {
  $fx = Join-Path $root 'regression-inputs\bakers-ad-2026-09-16'
  $me = $MyInvocation.MyCommand.Path
  $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('bkal-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmpRoot -ErrorAction Stop | Out-Null
  $script:stRan = 0; $script:stFail = 0
  function Test-BkalCase([string]$Label, [bool]$Ok, [string]$Got) {
    $script:stRan++
    if ($Ok) { Write-Output ('  ok    ' + $Label) } else { Write-Output ('  FAIL  ' + $Label + '   got: ' + $Got); $script:stFail++ }
  }
  function Invoke-BkalChild([string]$Name, [string[]]$ChildArgs) {
    $od = Join-Path $tmpRoot $Name
    New-Item -ItemType Directory -Path $od -ErrorAction Stop | Out-Null
    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $me -OutDir $od @ChildArgs)
    return [pscustomobject]@{ Rc = $LASTEXITCODE; Out = ($o -join "`n"); Dir = $od }
  }
  function Get-BkalList([string]$Dir) {
    $f = @(Get-ChildItem -LiteralPath (Join-Path $Dir 'bakers') -Filter 'bakers-ad-list-*.json' -File -ErrorAction SilentlyContinue)
    if ($f.Count -ne 1) { return $null }
    return (ConvertFrom-Json ([IO.File]::ReadAllText($f[0].FullName)))
  }
  $FIXID = '79d2baa2-eec6-4a91-9ffa-51c1c46fd2a4'
  try {
    if (-not (Test-Path -LiteralPath (Join-Path $fx 'root.json'))) { throw "the frozen fixture is missing: $fx" }

    # A. MUST FIRE - the founding case. The frozen 2026-09-16..09-22 ad, read on 09-18 for Saddlecreek: every one
    #    of its 169 offers is listed, and the engine's matcher routes the three cells the retired flyer used to
    #    carry (pasta-sauce via "Classico Pasta Sauce" in a BODY, coffee-pods via "K-Cups") plus chicken breast.
    $a = Invoke-BkalChild 'a' @('-FixtureDir', $fx, '-AdId', $FIXID, '-Today', '2026-09-18')
    $la = Get-BkalList $a.Dir
    $ta = @(); if ($la) { $ta = @(@($la.terms) | ForEach-Object { [string]$_.term }) }
    Test-BkalCase 'MUST FIRE  the frozen 2026-09-16 ad writes all 169 offers for Saddlecreek, and routed + unrouted = 169' `
      (($a.Rc -eq 0) -and $la -and ([int]$la.offer_count -eq 169) -and (@($la.offers).Count -eq 169) -and
       (([int]$la.routed_count + [int]$la.unrouted_count) -eq 169) -and ([string]$la.ad_from -eq '2026-09-16') -and ([string]$la.ad_to -eq '2026-09-22')) `
      ("rc=$($a.Rc) offers=$(if ($la) { $la.offer_count } else { 'no list' }) routed=$(if ($la) { $la.routed_count }) unrouted=$(if ($la) { $la.unrouted_count })")
    Test-BkalCase 'MUST FIRE  the router yields the pasta-sauce, coffee-pods and chicken-breast Baker''s terms' `
      (($ta -contains 'pasta sauce marinara') -and ($ta -contains 'coffee k cups') -and ($ta -contains 'boneless skinless chicken breast')) `
      ('terms: ' + (($ta | Select-Object -First 40) -join ', '))
    $pasta = @(@($la.offers) | Where-Object { [string]$_.id -eq '1292568' })
    Test-BkalCase 'MUST FIRE  a second product carried in the BODY is routed: 1292568 "Velveeta Shells & Cheese" | "...or Classico Pasta Sauce" reaches pasta-sauce' `
      (($pasta.Count -eq 1) -and (@($pasta[0].commodities) -contains 'pasta-sauce')) `
      ($(if ($pasta.Count) { 'commodities=' + (@($pasta[0].commodities) -join ',') } else { 'offer 1292568 missing' }))
    $unr = @(@($la.unrouted) | Where-Object { [string]$_.id -eq '1292580' })
    Test-BkalCase 'CLEAN TWIN  an offer the board does not track (1292580 Tito''s/Captain Morgan/Jose Cuervo) is RECORDED in unrouted[] with its phrases, never dropped' `
      (($unr.Count -eq 1) -and (@($unr[0].phrases).Count -ge 1)) ("unrouted 1292580 x$($unr.Count)")
    $idf = @(Get-ChildItem -LiteralPath (Join-Path $a.Dir 'bakers') -Filter 'bakers-ad-id-2026-09-16.json' -File -ErrorAction SilentlyContinue)
    Test-BkalCase 'CLEAN TWIN  the verified ad id is written beside the list, named for the ad''s own start date' `
      (($idf.Count -eq 1) -and ([string](ConvertFrom-Json ([IO.File]::ReadAllText($idf[0].FullName))).ad_id -eq $FIXID)) ("id files: $($idf.Count)")

    # B. MUST FIRE - a window that does not contain today refuses and writes nothing.
    $b = Invoke-BkalChild 'b' @('-FixtureDir', $fx, '-AdId', $FIXID, '-Today', '2026-09-25')
    Test-BkalCase 'MUST FIRE  an ad whose window (09-16..09-22) does not contain today (09-25) refuses: exit 1, no list' `
      (($b.Rc -eq 1) -and ($null -eq (Get-BkalList $b.Dir)) -and ($b.Out -match 'REFUSED')) ("rc=$($b.Rc)")

    # C. MUST FIRE - 0 offers for the location refuses (a store the ad does not list).
    $c = Invoke-BkalChild 'c' @('-FixtureDir', $fx, '-AdId', $FIXID, '-Today', '2026-09-18', '-Location', '99999999')
    Test-BkalCase 'MUST FIRE  an ad that lists 0 offers for the location refuses: exit 1, no list' `
      (($c.Rc -eq 1) -and ($null -eq (Get-BkalList $c.Dir)) -and ($c.Out -match '0 offer')) ("rc=$($c.Rc)")

    # D. MUST FIRE - one page that cannot be read refuses the whole list (a partial list silently drops sales).
    $fxD = Join-Path $tmpRoot 'fx-missing-page'
    Copy-Item -LiteralPath $fx -Destination $fxD -Recurse
    $gone = @(Get-ChildItem -LiteralPath (Join-Path $fxD 'pages') -Filter '*.json' -File | Sort-Object Name)[0]
    Remove-Item -LiteralPath $gone.FullName
    $d = Invoke-BkalChild 'd' @('-FixtureDir', $fxD, '-AdId', $FIXID, '-Today', '2026-09-18')
    Test-BkalCase 'MUST FIRE  a page that cannot be fetched refuses the whole list: exit 1, no list' `
      (($d.Rc -eq 1) -and ($null -eq (Get-BkalList $d.Dir)) -and ($d.Out -match 'page')) ("rc=$($d.Rc)")

    # E. MUST FIRE - an ad whose own adId is not the one asked for refuses (a stale or mistyped id).
    $e = Invoke-BkalChild 'e' @('-FixtureDir', $fx, '-AdId', '00000000-0000-0000-0000-000000000000', '-Today', '2026-09-18')
    Test-BkalCase 'MUST FIRE  an ad whose own adId differs from the id asked for refuses: exit 1, no list' `
      (($e.Rc -eq 1) -and ($null -eq (Get-BkalList $e.Dir))) ("rc=$($e.Rc)")

    # F. MUST FIRE - no ad id anywhere is its own exit code, so capture-run knows to read one in Chrome.
    $f = Invoke-BkalChild 'f' @('-FixtureDir', $fx, '-Today', '2026-09-18')
    Test-BkalCase 'MUST FIRE  no ad id anywhere exits 4 (NO AD ID) and writes nothing' `
      (($f.Rc -eq 4) -and ($null -eq (Get-BkalList $f.Dir))) ("rc=$($f.Rc)")

    # G. CLEAN TWIN - the browser path: the weekly-ad page's own resource URLs (as pull-browser-stores.py writes them)
    #    carry the id, and a run with no -AdId reads it from there and lists the ad.
    $g = Join-Path $tmpRoot 'g'
    New-Item -ItemType Directory -Path (Join-Path $g 'bakers') -Force | Out-Null
    $seen = [ordered]@{ captured = '2026-09-18T08:01:00'; source_url = 'https://www.bakersplus.com/weeklyad'
                        urls = @('https://www.bakersplus.com/weeklyad/weeklyad.js', ($script:DacsBase + '/' + $FIXID + '?location=61500319')) }
    [IO.File]::WriteAllText((Join-Path $g 'bakers\bakers-ad-id-seen-2026-09-18.json'), ($seen | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $go = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $me -OutDir $g -FixtureDir $fx -Today '2026-09-18')
    $grc = $LASTEXITCODE
    $lg = Get-BkalList $g
    Test-BkalCase 'CLEAN TWIN  with no -AdId, the id the weekly-ad page requested (bakers-ad-id-seen) is read, verified and listed' `
      (($grc -eq 0) -and $lg -and ([string]$lg.ad_id -eq $FIXID) -and ([string]$lg.id_source -eq 'browser')) ("rc=$grc list=$([bool]$lg)")
    # H. MUST NOT FIRE - a current list on disk is not re-pulled without -Force (the 08:00 run is once per ad week).
    $h = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $me -OutDir $g -FixtureDir $fx -Today '2026-09-19')
    $hrc = $LASTEXITCODE
    Test-BkalCase 'MUST NOT FIRE  a current list already on disk is not pulled again (exit 0, says current)' `
      (($hrc -eq 0) -and (($h -join "`n") -match 'already current')) ("rc=$hrc")
  } catch {
    $script:stFail++
    Write-Output ('  FAIL  the self-test threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:stRan -eq 0) { Write-Output 'pull-bakers-ad-list SELF-TEST FAIL (ran zero cases)'; exit 1 }
  if ($script:stFail) { Write-Output ('pull-bakers-ad-list SELF-TEST FAIL ({0} of {1} case(s) failed)' -f $script:stFail, $script:stRan); exit 1 }
  Write-Output ('pull-bakers-ad-list SELF-TEST PASS ({0} of {0} case(s))' -f $script:stRan)
  exit 0
}

# ============================================================================ helpers
. (Join-Path (Split-Path $root -Parent) 'lib\json-io.ps1')        # Read-JsonFile: a BOM-less file read as UTF-8
. (Join-Path (Split-Path $root -Parent) 'lib\atomic-write.ps1')   # Write-TcAtomicFile: capture-run and the lanes read these files
. (Join-Path $root 'capture-policy-lib.ps1')                      # Get-BakersAdListCurrent
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$todayS = if ($Today) { $Today } else { . (Join-Path $root 'omaha-time.ps1'); Get-OmahaDateKey }
$bkDir = Join-Path $OutDir 'bakers'

function Stop-BkalRefused([string]$Why, [int]$Code = 1) {
  Write-Output ('pull-bakers-ad-list: REFUSED - ' + $Why)
  Write-Output 'pull-bakers-ad-list: nothing written. The API lane keeps asking its rotation; check-ad-cycles and audit-ad-status page until a list lands.'
  exit $Code
}

function Get-BkalDacs([string]$AdGuid, [string]$Rel) {
  # $Rel is '' for the ad root or 'pages/<eventPageId>'.
  if ($FixtureDir) {
    $p = if ($Rel) { Join-Path $FixtureDir (($Rel -replace '/', '\') + '.json') } else { Join-Path $FixtureDir 'root.json' }
    if (-not (Test-Path -LiteralPath $p)) { throw ('the fixture has no ' + $(if ($Rel) { $Rel } else { 'root' })) }
    return (ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($p))))
  }
  $url = $script:DacsBase + '/' + $AdGuid + $(if ($Rel) { '/' + $Rel } else { '' }) + '?location=' + $Location
  $last = $null
  for ($try = 1; $try -le 2; $try++) {
    try {
      $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30
      # raw bytes decoded as UTF-8: PS 5.1 guesses the codepage and would mangle "L'Oreal" style names
      return (ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())))
    } catch { $last = $_.Exception.Message; Start-Sleep -Seconds 2 }
  }
  throw ('GET ' + $url + ' failed twice: ' + $last)
}

function Add-BkalPhrase($List, $Seen, [string]$Text) {
  $t = ([string]$Text).Trim().Trim(',').Trim()
  $t = $t -replace '^(?i)or\s+', ''
  if ($t -notmatch '[A-Za-z]{3,}') { return }
  if ($Seen.Add($t)) { [void]$List.Add($t) }
}

function Get-BkalPhrases([string]$Headline, [string]$Body) {
  # The candidate product phrases of one offer: the headline, the whole text, and every ';' then ' or ' fragment.
  $list = New-Object System.Collections.Generic.List[string]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $h = ([string]$Headline).Trim(); $b = (([string]$Body) -replace '\s+', ' ').Trim()
  $whole = if ($b) { $h + ', ' + $b } else { $h }
  Add-BkalPhrase $list $seen $h
  Add-BkalPhrase $list $seen $whole
  foreach ($seg in ($whole -split ';')) {
    foreach ($part in [regex]::Split($seg, '\s+or\s+', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
      Add-BkalPhrase $list $seen $part
    }
  }
  return ,($list.ToArray())
}

# ============================================================================ 0. already current?
if (-not $Force -and -not $AdId) {
  $cur = Get-BakersAdListCurrent -OutDir $OutDir -Date $todayS
  if ($cur.Doc) {
    Write-Output ("pull-bakers-ad-list: already current - {0} covers {1} ({2}..{3}); -Force re-pulls" -f $cur.Name, $todayS, $cur.AdFrom, $cur.AdTo)
    exit 0
  }
}

# ============================================================================ 1. which ad id
$cands = New-Object System.Collections.Generic.List[object]
$candIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if ($AdId) {
  if ($AdId -notmatch ('^' + $script:GuidRx + '$')) { Stop-BkalRefused ("-AdId '" + $AdId + "' is not a GUID (the id is the /api/dacs/<guid> the weekly-ad page requests)") }
  [void]$candIds.Add($AdId); [void]$cands.Add([pscustomobject]@{ id = $AdId.ToLowerInvariant(); source = 'parameter'; url = '' })
} else {
  foreach ($f in @(Get-ChildItem -LiteralPath $bkDir -Filter 'bakers-ad-id-*.json' -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.BaseName -match '^bakers-ad-id-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending)) {
    $d = $null; try { $d = Read-JsonFile $f.FullName } catch { continue }
    if ($d -and [string]$d.ad_id -match ('^' + $script:GuidRx + '$') -and [string]$d.ad_from -and [string]$d.ad_to -and
        [string]::CompareOrdinal(([string]$d.ad_from).Substring(0, 10), $todayS) -le 0 -and [string]::CompareOrdinal(([string]$d.ad_to).Substring(0, 10), $todayS) -ge 0) {
      if ($candIds.Add([string]$d.ad_id)) { [void]$cands.Add([pscustomobject]@{ id = ([string]$d.ad_id).ToLowerInvariant(); source = 'id-file'; url = [string]$d.source_url }) }
    }
  }
  $seenFiles = if ($SeenFile) { @(Get-Item -LiteralPath $SeenFile -ErrorAction SilentlyContinue) } else {
    @(Get-ChildItem -LiteralPath $bkDir -Filter 'bakers-ad-id-seen-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
  }
  foreach ($sf in $seenFiles) {
    if (-not $sf) { continue }
    $sd = $null; try { $sd = Read-JsonFile $sf.FullName } catch { continue }
    if (-not $sd) { continue }
    foreach ($u in @($sd.urls)) {
      $m = [regex]::Match([string]$u, ('/api/dacs/(' + $script:GuidRx + ')(?:[/?]|$)'))
      if ($m.Success) {
        $gid = $m.Groups[1].Value.ToLowerInvariant()
        if ($candIds.Add($gid)) { [void]$cands.Add([pscustomobject]@{ id = $gid; source = 'browser'; url = [string]$sd.source_url }) }
      }
    }
  }
}
if ($cands.Count -eq 0) {
  Write-Output ('pull-bakers-ad-list: NO AD ID for ' + $todayS + ' - no -AdId, no verified out\bakers\bakers-ad-id-*.json covering today, and no /api/dacs/<guid> in a bakers-ad-id-seen file.')
  Write-Output '  capture-run reads it in Chrome (pull-browser-stores.py --bakers-ad-id-out); by hand: open https://www.bakersplus.com/weeklyad on the Saddlecreek store and pass the /api/dacs/<guid> it requests as -AdId.'
  exit 4
}

# ============================================================================ 2. verify the ad against its own dates
$ad = $null; $adRoot = $null; $whyNot = New-Object System.Collections.Generic.List[string]
foreach ($c in $cands) {
  $r = $null
  try { $r = Get-BkalDacs $c.id '' } catch { [void]$whyNot.Add($c.id + ' (' + $c.source + '): ' + $_.Exception.Message); continue }
  if (-not [string]::Equals([string]$r.adId, [string]$c.id, [StringComparison]::OrdinalIgnoreCase)) {
    [void]$whyNot.Add($c.id + ' (' + $c.source + "): the ad answers as adId '" + [string]$r.adId + "', not the id asked for"); continue
  }
  $sd0 = ([string]$r.startDate); $ed0 = ([string]$r.endDate)
  if ($sd0.Length -lt 10 -or $ed0.Length -lt 10) { [void]$whyNot.Add($c.id + ': the ad states no startDate/endDate'); continue }
  $sd0 = $sd0.Substring(0, 10); $ed0 = $ed0.Substring(0, 10)
  if ([string]::CompareOrdinal($sd0, $todayS) -gt 0 -or [string]::CompareOrdinal($ed0, $todayS) -lt 0) {
    [void]$whyNot.Add($c.id + ' (' + $c.source + '): the ad runs ' + $sd0 + '..' + $ed0 + ', which does not contain ' + $todayS); continue
  }
  $ad = [pscustomobject]@{ id = [string]$c.id; source = $c.source; url = $c.url; from = $sd0; to = $ed0 }
  $adRoot = $r
  break
}
if (-not $ad) { Stop-BkalRefused ('no candidate ad id verified: ' + ($whyNot -join ' | ')) }

# ============================================================================ 3. every page, or nothing
$offers = New-Object System.Collections.Generic.List[object]
$offerIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$pages = @($adRoot.pages)
if ($pages.Count -eq 0) { Stop-BkalRefused ('ad ' + $ad.id + ' lists no pages') }
$notHere = 0
foreach ($p in $pages) {
  $pgId = [string]$p.eventPageId
  $plabel = [string]$p.page
  if (-not $pgId) { Stop-BkalRefused ('a page of ad ' + $ad.id + ' carries no eventPageId') }
  $pd = $null
  try { $pd = Get-BkalDacs $ad.id ('pages/' + $pgId) } catch { Stop-BkalRefused ('page ' + $plabel + ' (' + $pgId + ') could not be read: ' + $_.Exception.Message) }
  foreach ($cn in @($pd.contents)) {
    if ($null -eq $cn -or [string]$cn.contentType -ne 'Offer') { continue }
    $mc = $null
    try { $mc = ConvertFrom-Json ([string]$cn.mapConfig) } catch { Stop-BkalRefused ('page ' + $plabel + ': an Offer mapConfig is not JSON') }
    $o = $mc.content
    if ($null -eq $o -or -not [string]$o.id) { continue }
    $locs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    if ([string]$o.stores) {
      $sj = $null
      try { $sj = ConvertFrom-Json ([string]$o.stores) } catch { Stop-BkalRefused ('page ' + $plabel + ': offer ' + [string]$o.id + ' has an unreadable stores list') }
      foreach ($s in @($sj)) { foreach ($n in (([string]$s.locationNumbers) -split ',')) { $n2 = $n.Trim(); if ($n2) { [void]$locs.Add($n2) } } }
    }
    # An offer that does not NAME this store is not this store's sale - including one with no stores at all.
    if (-not $locs.Contains($Location)) { $notHere++; continue }
    if (-not $offerIds.Add([string]$o.id)) { continue }
    [void]$offers.Add([pscustomobject]@{ id = [string]$o.id; headline = ([string]$o.headline).Trim(); body = (([string]$o.bodyCopy) -replace '\s+', ' ').Trim(); page = $plabel })
  }
}
if ($offers.Count -eq 0) { Stop-BkalRefused ('ad ' + $ad.id + ' (' + $ad.from + '..' + $ad.to + ') lists 0 offers for location ' + $Location + ' (' + $notHere + ' offer(s) for other stores)') }

# ============================================================================ 4. route through the ENGINE'S matcher
. (Join-Path $root 'match-lib.ps1')
. (Join-Path $root 'global-exclude-lib.ps1')
$cdoc = Read-JsonFile (Join-Path $root 'commodities.json')
$commodities = if ($cdoc.PSObject.Properties['commodities']) { $cdoc.commodities } else { $cdoc }
$gex = Get-TcGlobalExclude
$matcher = New-CommodityMatcher -Commodities $commodities -GlobalExclude $gex
$search = Read-JsonFile (Join-Path $root 'commodity-search.json')
$termsOf = @{}
foreach ($pp in $search.terms.PSObject.Properties) {
  $tl = @(@($pp.Value) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
  if ($tl.Count) { $termsOf[[string]$pp.Name] = $tl }
}
$outOffers = New-Object System.Collections.Generic.List[object]
$unrouted = New-Object System.Collections.Generic.List[object]
$termRows = New-Object System.Collections.Generic.List[object]
$termSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($o in $offers) {
  $phr = Get-BkalPhrases $o.headline $o.body
  $cids = New-Object System.Collections.Generic.List[string]
  foreach ($ph in $phr) {
    $cm = Resolve-Commodity -Matcher $matcher -Name $ph
    if ($cm -and -not $cids.Contains([string]$cm.id)) { [void]$cids.Add([string]$cm.id) }
  }
  $oTerms = New-Object System.Collections.Generic.List[string]
  $noTerm = New-Object System.Collections.Generic.List[string]
  foreach ($cid in $cids) {
    if (-not $termsOf.ContainsKey($cid)) { [void]$noTerm.Add($cid); continue }
    foreach ($t in $termsOf[$cid]) {
      if (-not $oTerms.Contains($t)) { [void]$oTerms.Add($t) }
      if ($termSeen.Add($t)) { [void]$termRows.Add([pscustomobject][ordered]@{ id = $cid; term = $t }) }
    }
  }
  $row = [ordered]@{ id = $o.id; page = $o.page; headline = $o.headline; body = $o.body
                     commodities = $cids.ToArray(); terms = $oTerms.ToArray(); commodities_without_term = $noTerm.ToArray() }
  [void]$outOffers.Add([pscustomobject]$row)
  if ($oTerms.Count -eq 0) {
    [void]$unrouted.Add([pscustomobject][ordered]@{ id = $o.id; page = $o.page; headline = $o.headline; body = $o.body
                                                     phrases = $phr; commodities_without_term = $noTerm.ToArray() })
  }
}
$blind = $null
try { $blind = Get-CommodityMatcherBlind -Matcher $matcher } catch { $blind = $null }
$cnl = if ($blind) { @($blind.could_not_look).Count } else { 0 }
$routedN = $outOffers.Count - $unrouted.Count

# ============================================================================ 5. write (the id first: the list names it)
if (-not (Test-Path -LiteralPath $bkDir)) { New-Item -ItemType Directory -Path $bkDir -Force | Out-Null }
$now = (Get-Date).ToString('s')
$srcUrl = if ($ad.url) { $ad.url } else { 'https://www.bakersplus.com/weeklyad' }
$idDoc = [ordered]@{
  store = "Baker's"; ad_id = $ad.id; location = $Location; week_number = [string]$adRoot.weekNumber
  ad_from = $ad.from; ad_to = $ad.to; circular_type = [string]$adRoot.circularType
  captured = $now; source = $ad.source; source_url = $srcUrl
  note = 'Verified by pull-bakers-ad-list.ps1: the dacs root answered with this adId and a window containing the capture day.'
}
$listDoc = [ordered]@{
  store = "Baker's"; ad_id = $ad.id; id_source = $ad.source; week_number = [string]$adRoot.weekNumber
  ad_from = $ad.from; ad_to = $ad.to; location = $Location; captured = $now; read_on = $todayS
  source_url = ($script:DacsBase + '/' + $ad.id + '?location=' + $Location)
  pages = $pages.Count; offer_count = $outOffers.Count; offers_for_other_stores = $notHere
  routed_count = $routedN; unrouted_count = $unrouted.Count; term_count = $termRows.Count
  matcher_could_not_look = $cnl
  note = ('The weekly ad LIST, not its prices: the Kroger API prices every term below when capture-policy''s Get-BakersAdOwed hands it to pull-regular-bakers-api.ps1. Routed through match-lib Resolve-Commodity over commodities.json; unrouted offers are listed with the phrases tried.')
  terms = $termRows.ToArray()
  offers = $outOffers.ToArray()
  unrouted = $unrouted.ToArray()
}
$idPath = Join-Path $bkDir ('bakers-ad-id-' + $ad.from + '.json')
$listPath = Join-Path $bkDir ('bakers-ad-list-' + $ad.from + '.json')
[void](Write-TcAtomicFile -Path $idPath -Text ((($idDoc | ConvertTo-Json -Depth 6) -replace "`r`n", "`n") + "`n") -NoBom -NoNewline)
[void](Write-TcAtomicFile -Path $listPath -Text ((($listDoc | ConvertTo-Json -Depth 8) -replace "`r`n", "`n") + "`n") -NoBom -NoNewline)

Write-Output ("pull-bakers-ad-list: ad {0} week {1} {2}..{3} (id from {4}) - {5} page(s), {6} offer(s) for {7}" -f $ad.id, $adRoot.weekNumber, $ad.from, $ad.to, $ad.source, $pages.Count, $outOffers.Count, $Location)
Write-Output ("pull-bakers-ad-list: routed {0} of {1} offer(s) onto {2} Baker's search term(s); {3} unrouted (listed in the file){4}" -f $routedN, $outOffers.Count, $termRows.Count, $unrouted.Count, $(if ($cnl) { "; matcher could not look at $cnl name(s)" } else { '' }))
Write-Output ("pull-bakers-ad-list: wrote " + (Split-Path $listPath -Leaf) + ' and ' + (Split-Path $idPath -Leaf))
exit 0
