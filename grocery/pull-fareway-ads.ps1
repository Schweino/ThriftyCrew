<#
  pull-fareway-ads.ps1 - Fareway's weekly + monthly ad, fully server-side (NO browser, no bot wall - unlike
  Baker's). Fareway hosts its Omaha ad as page JPGs on its own CDN with the SALE DATES ENCODED IN THE FILENAME
  (OmahaGroup_weekly_MMDDYYYY_MMDDYYYY-N.jpg), so the pull self-updates and self-verifies week to week.

  Enforces the same TWO HARD GATES as pull-grocery-ads.ps1:
    OMAHA   - the image path must be the OmahaGroup ad group (store 043 = Omaha).
    CURRENT - today must fall inside the ad's valid_from..valid_to (parsed from the filename).
  Fail either -> that ad is BLOCKED and no pages are downloaded (nothing wrong-city / stale can leak through).

  THIRD GATE, added 2026-08-09: COMPLETE + CLEAN. Pages download to a <kind>.staging dir and are swapped in
  only when every intended page arrived; the live dir is cleared first so a SHRINKING ad cannot leave the
  previous ad's extra pages behind. See adpages-lib.ps1 for the full contract and the founding incident
  (a 22-page ad over a 24-page one left weekly-23/24 from the expired ad on disk, where the vision-read
  step's out\fareway\weekly\*.jpg glob would have read them as current).

  Downloads each page JPG to out\fareway\<weekly|monthly>\ and writes out\fareway\fareway-ad-manifest-<date>.json
  { generated, weekly:{from,to,pages,dir,blocked}, monthly:{...} } for the vision-read step to consume.
  READ THE MANIFEST, NOT THE GLOB: on_disk_from/on_disk_to name the window the images actually belong to
  (also stamped into each dir as ad-window.json), which is NOT the new ad's window when an install was
  refused. `pages` counts pages of the CURRENT ad available - it is 0 when blocked, even if the folder is full.
  The store storefront (shop.fareway.com) is the everyday+sale price source; these ad images are the SALE
  supplement (some ad promos aren't shown online).

  Exit 0 = both ads resolved (installed, or cleanly blocked by the Omaha/current gates).
  Exit 2 = an install or a post-install assertion FAILED - the images on disk are not what the ad says.
#>
param([string]$OutDir = "", [string]$Today = "", [switch]$SelfTest)
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'adpages-lib.ps1')

# ---------------------------------------------------------------- SELF-TEST (hermetic, no network)
# The must-fire case is the 2026-08-09 incident itself, frozen in guard-fixtures\adpages-shrink.json.
if ($SelfTest) {
  $fxFile = Join-Path $root 'regression-inputs\guard-fixtures\adpages-shrink.json'
  if (-not (Test-Path $fxFile)) { Write-Output ("SELFTEST FAIL: missing frozen fixture " + $fxFile); exit 2 }
  $fx = Get-Content $fxFile -Raw | ConvertFrom-Json
  $pfx = [string]$fx.prefix
  $priorN = [int]$fx.prior.pages; $curN = [int]$fx.current.pages
  $tp = 0; $tf = 0
  function T($ok, $m) { if ($ok) { Write-Output ('  PASS  ' + $m); $script:tp++ } else { Write-Output ('  FAIL  ' + $m); $script:tf++ } }
  $filler = ('x' * 6000)   # every page must clear AdPageMinBytes or it reads as a truncated download
  function Seed($dir, $prefix, [int[]]$nums) {
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null
    foreach ($n in $nums) { Set-Content (Join-Path $dir ("$prefix-$n.jpg")) $filler -Encoding ASCII }
    return $dir
  }
  $tmp = Join-Path $env:TEMP ('adpages-selftest-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Force $tmp | Out-Null
  Write-Output ('pull-fareway-ads -SelfTest: the ' + $fx.current.from + ' shrinking-ad case (' + $priorN + ' pages -> ' + $curN + ')')

  # (1) MUST FIRE - the folder as the OLD code left it: the new ad's 22 pages PLUS the expired ad's 23 and 24.
  $d1 = Seed (Join-Path $tmp 'mustfire') $pfx (1..$priorN)
  $a1 = Test-AdPageSet -Dir $d1 -Prefix $pfx -Expected (1..$curN)
  $namesFire = @($fx.orphans_left_by_the_bug | ForEach-Object { "$pfx-$_.jpg" })
  $sawBoth = $true; foreach ($n in $namesFire) { if ($a1.reason -notmatch [regex]::Escape($n)) { $sawBoth = $false } }
  T ((-not $a1.ok) -and $sawBoth -and @($a1.extra).Count -eq ($priorN - $curN)) `
    ('MUST FIRE: ' + $priorN + ' files on disk against a ' + $curN + '-page ad is reported as orphaned, naming ' + ($namesFire -join ' + '))

  # (2) CLEAN TWIN - exactly the pages the ad has. Must stay silent, or the assertion is just noise.
  $d2 = Seed (Join-Path $tmp 'clean') $pfx (1..$curN)
  $a2 = Test-AdPageSet -Dir $d2 -Prefix $pfx -Expected (1..$curN)
  T ($a2.ok -and $a2.count -eq $curN) ('CLEAN TWIN: a folder holding exactly ' + $curN + ' pages passes silently')

  # (3) THE FIX, END TO END - prior ad on disk, new ad staged, swap. This is the mutation proof: with the
  #     old download-in-place code the orphans survive; with the clear-first swap they cannot.
  $d3 = Seed (Join-Path $tmp 'install')  $pfx (1..$priorN)
  $s3 = Seed (Join-Path $tmp 'staging3') $pfx (1..$curN)
  $i3 = Install-AdPages -Dir $d3 -Staging $s3 -Prefix $pfx -Expected (1..$curN) -Stamp @{ from=$fx.current.from; to=$fx.current.to }
  $left3 = Get-AdPageMap -Dir $d3 -Prefix $pfx
  $orphGone = $true; foreach ($n in $fx.orphans_left_by_the_bug) { if ($left3.ContainsKey([int]$n)) { $orphGone = $false } }
  T ($i3.ok -and @($left3.Keys).Count -eq $curN -and $orphGone) `
    ('INSTALL clears first: after the swap the folder holds exactly ' + $curN + ' pages and the expired ' + (($fx.orphans_left_by_the_bug) -join '/') + ' are gone')
  $st3 = Read-AdWindowStamp -Dir $d3
  T ($st3 -and [string]$st3.from -eq [string]$fx.current.from -and [int]$st3.pages -eq $curN) `
    ('INSTALL stamps ad-window.json with the window the images belong to (' + $fx.current.from + ', ' + $curN + ' pages)')

  # (4) INCOMPLETE DOWNLOAD must not wipe the store's ad - and must not half-swap either.
  $d4 = Seed (Join-Path $tmp 'partial')  $pfx (1..$priorN)
  $null = Install-AdPages -Dir $d4 -Staging (Seed (Join-Path $tmp 'stagingP') $pfx (1..$priorN)) -Prefix $pfx -Expected (1..$priorN) -Stamp @{ from=$fx.prior.from; to=$fx.prior.to }
  $s4 = Seed (Join-Path $tmp 'staging4') $pfx (1..([int]$fx.partial_download_pages))
  $i4 = Install-AdPages -Dir $d4 -Staging $s4 -Prefix $pfx -Expected (1..$curN) -Stamp @{ from=$fx.current.from; to=$fx.current.to }
  $left4 = Get-AdPageMap -Dir $d4 -Prefix $pfx
  T ((-not $i4.ok) -and @($left4.Keys).Count -eq $priorN -and $i4.reason -match 'incomplete') `
    ('PARTIAL download refused: ' + $fx.partial_download_pages + ' of ' + $curN + ' staged leaves the previous ' + $priorN + '-page ad intact, no half-swap')
  $st4 = Read-AdWindowStamp -Dir $d4
  T ($st4 -and [string]$st4.from -eq [string]$fx.prior.from) `
    ('PARTIAL download stays HONEST: ad-window.json still reads ' + $fx.prior.from + ', so no reader can mistake the leftovers for the new ad')

  # (5) The clear is scoped. out\bakers\ holds deals JSON and urls.txt beside the pages; a wildcard delete
  #     would take them with it.
  $d5 = Seed (Join-Path $tmp 'siblings') 'page' (1..$priorN)
  foreach ($sib in $fx.sibling_files_that_must_survive_the_clear) { Set-Content (Join-Path $d5 $sib) 'keep me' -Encoding UTF8 }
  $s5 = Seed (Join-Path $tmp 'staging5') 'page' (1..$curN)
  $i5 = Install-AdPages -Dir $d5 -Staging $s5 -Prefix 'page' -Expected (1..$curN) -Stamp @{ from=$fx.current.from }
  $sibsOk = $true; foreach ($sib in $fx.sibling_files_that_must_survive_the_clear) { if (-not (Test-Path (Join-Path $d5 $sib))) { $sibsOk = $false } }
  T ($i5.ok -and $sibsOk) 'SCOPED clear: sibling data files (deals JSON, urls.txt, meta.json) survive the page wipe'

  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Write-Output ("SELFTEST " + $(if ($tf -eq 0) { 'PASS' } else { 'FAIL' }) + ": $tp passed, $tf failed")
  exit $(if ($tf -eq 0) { 0 } else { 2 })
}

# ---------------------------------------------------------------- live pull
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$fwDir = Join-Path $OutDir 'fareway'
New-Item -ItemType Directory -Force -Path $fwDir | Out-Null
$asof = if ($Today) { [datetime]::ParseExact($Today,'yyyy-MM-dd',$null) } else { (Get-Date).Date }
$asofS = $asof.ToString('yyyy-MM-dd')
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'

function Get-AdPages([string]$kind) {
  # kind = 'weekly' or 'monthly'
  $url = "https://www.fareway.com/stores/043/ad/$kind`?embedded"
  $dir = Join-Path $fwDir $kind
  # on_disk_* describe what a reader globbing $dir will actually SEE, which is not the same thing as the ad
  # we just found online - the whole point of the 2026-08-09 fix.
  $res = [ordered]@{ from=''; to=''; pages=0; dir=$dir; blocked=$true; reason=''
                     ad_pages=0; page_gaps=@(); on_disk=0; on_disk_from=''; on_disk_to=''; install_failed=$false }
  function Set-OnDisk($r) {
    $st = Read-AdWindowStamp -Dir $dir
    $r.on_disk = @((Get-AdPageMap -Dir $dir -Prefix $kind).Keys).Count
    $r.on_disk_from = $(if ($st) { [string]$st.from } else { '' })
    $r.on_disk_to   = $(if ($st) { [string]$st.to }   else { '' })
  }
  try { $html = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -Headers @{'User-Agent'=$ua}).Content }
  catch { $res.reason = "fetch failed: $($_.Exception.Message)"; Set-OnDisk $res; return $res }
  # image paths: /media/stores/adGroups/NN/OmahaGroup_<kind>_MMDDYYYY_MMDDYYYY-N.jpg
  $rx = "/media/stores/adGroups/\d+/OmahaGroup_${kind}_(\d{8})_(\d{8})-(\d+)\.jpg"
  $matches = [regex]::Matches($html, $rx)
  if ($matches.Count -eq 0) { $res.reason = 'no OmahaGroup ad images found (wrong city or ad markup changed)'; Set-OnDisk $res; return $res }
  $fromRaw = $matches[0].Groups[1].Value; $toRaw = $matches[0].Groups[2].Value

  # THE STORE TYPOS ITS OWN FILENAMES, AND THAT USED TO CRASH THE PULL.
  # Observed live 2026-08-20: OmahaGroup_weekly_08162026_80222026-N.jpg. The end
  # date reads "80222026" - month EIGHTY - because 0822 was transposed to 8022.
  # ParseExact threw, $ErrorActionPreference='Stop' took the whole run down, and
  # the operator saw a raw FormatException rather than "Fareway's ad is unreadable".
  # An upstream typo must never be an unhandled exception here.
  #
  # THE REPAIR IS NARROW AND ON THE RECORD. Only a transposed leading pair is
  # undone (8022 -> 0822), and only when the result is a date that is AFTER the
  # ad's own valid start and no more than 31 days later. That is evidence, not a
  # guess: the start date parsed cleanly, the previous ad ended the day before it,
  # and the store's cadence puts the end exactly where the repair lands. Anything
  # that fails those checks stays BLOCKED - a wrong window would publish sale
  # prices outside their validity, which is the failure the CURRENT gate exists
  # to prevent. The manifest records to_raw and to_repaired so the repair is
  # auditable and this never becomes an invisible fixup.
  function Parse-AdDate([string]$raw) {
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($raw,'MMddyyyy',$null,[Globalization.DateTimeStyles]::None,[ref]$d)) { return $d }
    return $null
  }
  $from = Parse-AdDate $fromRaw
  $to   = Parse-AdDate $toRaw
  $res.to_raw = $toRaw; $res.to_repaired = $false
  if (-not $from) { $res.reason = "unreadable ad START date in filename ('$fromRaw')"; Set-OnDisk $res; return $res }
  if (-not $to -and $toRaw.Length -eq 8) {
    $swap = $toRaw.Substring(1,1) + $toRaw.Substring(0,1) + $toRaw.Substring(2)
    $cand = Parse-AdDate $swap
    if ($cand -and $cand -gt $from -and ($cand - $from).Days -le 31) {
      $to = $cand; $res.to_repaired = $true
      Write-Warning ("Fareway ${kind}: the store's filename carries an impossible end date '$toRaw'; read as '$swap' (" + $to.ToString('yyyy-MM-dd') + ") - a transposed leading pair, consistent with the ad start " + $from.ToString('yyyy-MM-dd') + ". Recorded as repaired in the manifest.")
    }
  }
  if (-not $to) { $res.reason = "unreadable ad END date in filename ('$toRaw')"; Set-OnDisk $res; return $res }
  $res.from = $from.ToString('yyyy-MM-dd'); $res.to = $to.ToString('yyyy-MM-dd')
  # CURRENT gate: today within [from, to]
  if ($asof -lt $from -or $asof -gt $to) { $res.reason = "not current (ad $($res.from)..$($res.to), today $asofS)"; Set-OnDisk $res; return $res }
  # distinct page paths, ordered by page number
  $paths = @{}
  foreach ($m in $matches) { $paths[[int]$m.Groups[3].Value] = $m.Value }
  $ordered = $paths.GetEnumerator() | Sort-Object Name
  $wanted = @(@($paths.Keys) | Sort-Object)
  $res.ad_pages = $wanted.Count
  $res.page_gaps = @(Get-AdPageGaps -Pages $wanted)

  # STAGE, then swap. Never download into $dir: a shrinking ad would leave the previous ad's extra pages
  # behind, and a failed download would leave the store with a half-current folder.
  $staging = New-AdStagingDir (Join-Path $fwDir ($kind + '.staging'))
  foreach ($p in $ordered) {
    $u = 'https://www.fareway.com' + $p.Value
    $o = Join-Path $staging ("$kind-$($p.Name).jpg")
    try { Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 40 -Headers @{'User-Agent'=$ua} -OutFile $o } catch {}
  }
  $inst = Install-AdPages -Dir $dir -Staging $staging -Prefix $kind -Expected $wanted `
                          -Stamp @{ from=$res.from; to=$res.to; store='Fareway'; ad_group='OmahaGroup (043)'; pulled=$asofS }
  Set-OnDisk $res
  if (-not $inst.ok) {
    # pages stays 0: zero pages of THIS ad are readable. on_disk_* say what is actually in the folder.
    $res.reason = $inst.reason; $res.install_failed = $true
    return $res
  }
  $res.pages = $inst.installed; $res.blocked = $false
  $res.reason = "OK ($($inst.installed) pages)"
  if ($res.page_gaps.Count) { $res.reason += ('  [source numbering gap: missing page ' + ($res.page_gaps -join ', ') + ']') }
  return $res
}

$weekly  = Get-AdPages 'weekly'
$monthly = Get-AdPages 'monthly'
$manifest = [ordered]@{ generated=$asofS; store='Fareway'; ad_group='OmahaGroup (043)'; weekly=$weekly; monthly=$monthly }
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $fwDir "fareway-ad-manifest-$asofS.json") -Encoding UTF8

function Show([string]$label, $r) {
  if (-not $r.blocked) {
    Write-Output ("$label : $($r.pages) pages  $($r.from)..$($r.to)")
  } else {
    Write-Output ("$label : BLOCKED - " + $r.reason)
    # A blocked pull that leaves images behind is the dangerous state: they are a CLOSED ad's pages and the
    # vision-read glob cannot tell. Say so on the console, not just in the manifest.
    if ($r.on_disk -gt 0) {
      $w = if ($r.on_disk_from) { "$($r.on_disk_from)..$($r.on_disk_to)" } else { 'unknown window (pulled before ad-window.json existed)' }
      Write-Output ("           WARNING: $($r.on_disk) page(s) remain in $($r.dir) from $w - do NOT vision-read them as current.")
    }
  }
}
Show 'Fareway weekly ' $weekly
Show 'Fareway monthly' $monthly

# Only an INSTALL/assertion failure is an error. A clean Omaha/current block is a normal, correct outcome.
if ($weekly.install_failed -or $monthly.install_failed) {
  Write-Output ''
  Write-Output 'FAILED: the pages on disk do not match the ad. Re-run; if it persists the CDN is serving an incomplete set.'
  exit 2
}
