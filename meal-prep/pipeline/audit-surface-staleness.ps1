<#
  audit-surface-staleness.ps1 - do the four reader-facing PRICE SURFACES still agree with the manifest?

  WHY THIS EXISTS (2026-09-01). Four surfaces carry a per-serving or per-batch price baked in at build
  time: the meal-prep hub grid, and the three tool pages (cheap dinners, what's for dinner, payday
  stretcher). All four are built from meal-prep\pipeline\v2-perserving.json. NOTHING AUTOMATED CALLED ANY
  OF THEIR BUILDERS. They were run by hand, when someone remembered, and the measurement on the day this
  was written says what that costs:

      hub live data-cost      576 rows: 135 agree / 440 disagree with the manifest
      cheapnow-data.js        576 rows:  71 agree / 504 disagree
      dinner-data.js          513 rows:   7 agree / 499 disagree, 74 catalog recipes ABSENT, 7 retired
      stretcher-data.js       513 rows:   0 agree / 506 disagree, 74 ABSENT, 7 retired, and 299 of its
                                          rows carried one identical batch cost

  MEASURE THE OUTCOME, NOT THE FILE. The three tool pages hydrate every row from the live feed at page
  load, so a stale baked figure there is a fallback, not what a reader sees - verified on the live pages
  that day (424 divergent rows on cheap-dinners, and the reader saw the FEED value in 424 of 424). The
  HUB does not hydrate: its price is a static data-cost attribute, and the reader saw the stale value in
  143 of 143. That asymmetry is why this guard reports per surface and does not average them.

  WHAT IT REFUSES. Any row where a surface disagrees with the manifest by MORE THAN A PENNY. A penny is
  the rounding both sides do, so a penny is noise and anything past it is drift.

  A SURFACE IS ALSO WRONG WHEN A RECIPE IS NOT ON IT. A price diff cannot see 74 missing recipes, which
  was the larger defect on two of the four. Absent and retired rows are counted and reported; absent rows
  fail, because a reader cannot choose a dinner the tool does not list.

  EXIT: 0 clean / 1 findings / 2 self-test failed / 3 could-not-evaluate.
  Self-test: powershell -File meal-prep\pipeline\audit-surface-staleness.ps1 -SelfTest
#>
param([switch]$SelfTest, [switch]$ShowAll, [switch]$SkipHub)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path $here -Parent
$repo = Split-Path $mp -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$script:TOL_CENTS = 1   # a penny, in whole cents. Both sides round to cents, so one cent is noise
                        # and anything past it is drift. Cents, not doubles: see Get-StalenessFindings.

function Get-SurfaceRows {
  <# Parse one surface's text into slug -> displayed dollars. PURE: takes text, touches no file, so the
     fixtures below can drive it with a frozen string instead of a live artifact.

     Kind is the surface's own payload shape:
       CN   cheap-dinners      {"s":"slug", ... "c":2.54}          per serving
       DIN  what's for dinner  {"s":"slug", ... "c":2.54}          per serving
       PSD  payday stretcher   {s:"slug",v:14,b:34.37, ...}        per BATCH, so divide by servings
       HUB  hub grid           data-cost="2.54" ... href=".../slug/"
     Returns a hashtable. An unparsable surface returns an EMPTY hashtable and the caller treats that as
     could-not-evaluate, never as clean - "no rows" and "no findings" are different answers. #>
  param([string]$Text, [ValidateSet('CN','DIN','PSD','HUB')][string]$Kind)
  $rows = @{}
  if ([string]::IsNullOrEmpty($Text)) { return $rows }
  switch ($Kind) {
    'PSD' {
      foreach ($m in [regex]::Matches($Text, 's:"(?<s>[^"]+)",v:(?<v>\d+),b:(?<b>-?[0-9.]+)')) {
        $v = [double]$m.Groups['v'].Value
        if ($v -gt 0) { $rows[$m.Groups['s'].Value] = [math]::Round([double]$m.Groups['b'].Value / $v, 2) }
      }
    }
    'HUB' {
      foreach ($m in [regex]::Matches($Text, 'data-cost="(?<c>[0-9.]+)"[^>]*href="https://www\.thriftycrew\.com/(?<s>[a-z0-9-]+)/"')) {
        $rows[$m.Groups['s'].Value] = [double]$m.Groups['c'].Value
      }
    }
    default {
      # CN and DIN share a shape. DIN's payload has an ingredient array first whose objects carry "n"
      # but never "s", so anchoring on "s" cannot pick one up.
      foreach ($m in [regex]::Matches($Text, '"s":"(?<s>[^"]+)"[^{}]*?"c":(?<c>-?[0-9.]+)')) {
        $rows[$m.Groups['s'].Value] = [double]$m.Groups['c'].Value
      }
    }
  }
  return $rows
}

function Get-StalenessFindings {
  <# PURE. Compare one surface's rows against the manifest and the catalog. Returns an array of strings.
     $Manifest and $Catalog are hashtables slug -> cheapest_ps / name. #>
  param($Rows, $Manifest, $Catalog, [string]$Label)
  $out = @()
  foreach ($slug in @($Rows.Keys | Sort-Object)) {
    if (-not $Manifest.ContainsKey($slug)) {
      if ($Catalog -and -not $Catalog.ContainsKey($slug)) { $out += ("{0}: RETIRED '{1}' is still listed on this surface" -f $Label, $slug) }
      continue
    }
    # COMPARED IN WHOLE CENTS, ON PURPOSE. In doubles, 3.40 - 3.39 is 0.010000000000000231, which is
    # -gt 0.01, so an exact one-cent difference reported as drift. AwayFromZero because [math]::Round
    # defaults to banker's rounding and would take 2.5 cents down to 2.
    $want = [double]$Manifest[$slug]
    $got  = [double]$Rows[$slug]
    $wantC = [int][math]::Round($want * 100, [MidpointRounding]::AwayFromZero)
    $gotC  = [int][math]::Round($got  * 100, [MidpointRounding]::AwayFromZero)
    $dC = [math]::Abs($gotC - $wantC)
    if ($dC -gt $script:TOL_CENTS) {
      $out += ("{0}: STALE '{1}' shows {2:N2}, manifest says {3:N2} (off by {4:N2})" -f $Label, $slug, ($gotC/100.0), ($wantC/100.0), ($dC/100.0))
    }
  }
  if ($Catalog) {
    foreach ($slug in @($Catalog.Keys | Sort-Object)) {
      if (-not $Rows.ContainsKey($slug)) { $out += ("{0}: ABSENT '{1}' is in the catalog but not on this surface" -f $Label, $slug) }
    }
  }
  # RETURNED BARE, and every caller wraps the call in @(). The defensive `,$out` that was here first
  # is the PS 5.1 trap the other way round: comma-wrapping an EMPTY array yields @(@()), which reads as
  # one finding, so a clean surface reported itself dirty. @() at the call site handles all three cases.
  return $out
}

# =====================================================================================================
if ($SelfTest) {
  $bad = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:bad++ } }

  # THE FROZEN MUST-FIRE, lifted from the real divergence measured 2026-09-01: cheapnow-data.js carried
  # 2.92 for slow-cooker-tuscan-chicken-pasta while the manifest said 3.39. Frozen as a string, never
  # regenerated from the live surface - regenerate it and the row agrees, and the fixture proves nothing.
  $STALE_CN = '/*CN-DATA*/var CN={rec:[{"n":"Slow Cooker Tuscan Chicken Pasta","s":"slow-cooker-tuscan-chicken-pasta","sv":14,"cal":600,"p":40,"c":2.92}]};/*CN-END*/'
  $CLEAN_CN = '/*CN-DATA*/var CN={rec:[{"n":"Slow Cooker Tuscan Chicken Pasta","s":"slow-cooker-tuscan-chicken-pasta","sv":14,"cal":600,"p":40,"c":3.39}]};/*CN-END*/'
  $MAN  = @{ 'slow-cooker-tuscan-chicken-pasta' = 3.39 }
  $CAT  = @{ 'slow-cooker-tuscan-chicken-pasta' = 'Slow Cooker Tuscan Chicken Pasta' }

  $r = Get-SurfaceRows $STALE_CN 'CN'
  T 'the cheap-dinners payload parses to one row' ($r.Count -eq 1 -and $r['slow-cooker-tuscan-chicken-pasta'] -eq 2.92) ($r.Count)
  $f = @(Get-StalenessFindings $r $MAN $CAT 'cheapnow')
  T 'MUST FIRE  a surface row 47 cents behind the manifest is a finding (the real 2026-09-01 row)' `
    ($f.Count -eq 1 -and $f[0] -match 'STALE') (($f -join ' | '))

  $f2 = @(Get-StalenessFindings (Get-SurfaceRows $CLEAN_CN 'CN') $MAN $CAT 'cheapnow')
  T 'CLEAN TWIN  the same surface agreeing with the manifest is silent' ($f2.Count -eq 0) (($f2 -join ' | '))

  # THE PENNY BOUNDARY, both sides of it. Rounding is noise; two pennies is drift.
  $penny = '/*CN-DATA*/var CN={rec:[{"n":"X","s":"slow-cooker-tuscan-chicken-pasta","sv":14,"cal":1,"p":1,"c":3.40}]};'
  T 'CLEAN TWIN  a one-cent difference is rounding, not drift' `
    ((@(Get-StalenessFindings (Get-SurfaceRows $penny 'CN') $MAN $CAT 'x')).Count -eq 0) 'a penny was reported'
  $twoc = '/*CN-DATA*/var CN={rec:[{"n":"X","s":"slow-cooker-tuscan-chicken-pasta","sv":14,"cal":1,"p":1,"c":3.41}]};'
  T 'MUST FIRE  two cents is past the tolerance and is reported' `
    ((@(Get-StalenessFindings (Get-SurfaceRows $twoc 'CN') $MAN $CAT 'x')).Count -eq 1) 'two cents slipped through'

  # A MISSING RECIPE IS THE DEFECT A PRICE DIFF CANNOT SEE. 74 of them were live on two surfaces.
  $catBig = @{ 'slow-cooker-tuscan-chicken-pasta' = 'A'; 'street-corn-chicken-rice-bowls' = 'B' }
  $manBig = @{ 'slow-cooker-tuscan-chicken-pasta' = 3.39; 'street-corn-chicken-rice-bowls' = 2.00 }
  $f3 = @(Get-StalenessFindings (Get-SurfaceRows $CLEAN_CN 'CN') $manBig $catBig 'cheapnow')
  T 'MUST FIRE  a catalog recipe missing from the surface is a finding even when every price agrees' `
    ($f3.Count -eq 1 -and $f3[0] -match 'ABSENT') (($f3 -join ' | '))

  # A RETIRED RECIPE STILL ON THE SURFACE. 7 of them were live on two surfaces.
  $f4 = @(Get-StalenessFindings (Get-SurfaceRows $CLEAN_CN 'CN') @{} @{} 'cheapnow')
  T 'MUST FIRE  a slug in neither the manifest nor the catalog is reported as retired' `
    ($f4.Count -eq 1 -and $f4[0] -match 'RETIRED') (($f4 -join ' | '))

  # THE BATCH SURFACE IS PER BATCH. Reading b as a per-serving figure would call every row stale.
  $psd = 'var PSD={rec:[{n:"X",s:"slow-cooker-tuscan-chicken-pasta",v:14,b:47.46,p:1,k:1,pr:"c"}]};'
  $pr = Get-SurfaceRows $psd 'PSD'
  T 'the stretcher payload is divided by servings before it is compared (47.46 / 14 = 3.39)' `
    ($pr['slow-cooker-tuscan-chicken-pasta'] -eq 3.39) ($pr['slow-cooker-tuscan-chicken-pasta'])

  # THE HUB IS A STATIC ATTRIBUTE ON A LIVE PAGE, not a JS payload.
  $hub = '<a class="mpr-card" data-protein="chicken" data-cal="600" data-cost="2.92" data-ppd="13.7" data-cuisine="Italian" href="https://www.thriftycrew.com/slow-cooker-tuscan-chicken-pasta/">x</a>'
  $hr = Get-SurfaceRows $hub 'HUB'
  T 'MUST FIRE  the hub grid parses and its static data-cost is compared like any other surface' `
    ($hr['slow-cooker-tuscan-chicken-pasta'] -eq 2.92 -and (@(Get-StalenessFindings $hr $MAN $CAT 'hub')).Count -eq 1) 'hub row not read'

  # AN UNPARSABLE SURFACE MUST NOT READ AS CLEAN. This is the fail-open shape the estate has been bitten
  # by repeatedly: a changed payload shape would silently yield zero rows and zero findings forever.
  T 'MUST FIRE  a surface whose payload shape has changed yields NO rows, so the caller can refuse' `
    ((Get-SurfaceRows 'var CN={};' 'CN').Count -eq 0) 'invented rows'

  # AND IT MUST ACTUALLY RUN. A detector nobody calls detects nothing, which is the whole reason the four
  # builders drifted: every ingredient of this check could have been written any day for six weeks.
  $chain = Join-Path $repo 'grocery\check-ad-cycles.ps1'
  $chainSrc = if (Test-Path $chain) { Get-Content $chain -Raw -Encoding utf8 } else { '' }
  T 'MUST FIRE  the daily chain invokes this guard' ($chainSrc -match 'audit-surface-staleness\.ps1') 'not wired into check-ad-cycles'
  foreach ($b in @('build-hub-grid.ps1','build-cheapnow-data.ps1','build-dinner-data.ps1','build-stretcher-data.ps1')) {
    T ("MUST FIRE  the daily chain rebuilds $b, or this guard just reports the same drift every day") `
      ($chainSrc -match [regex]::Escape($b)) 'not wired into check-ad-cycles'
  }
  # ORDER IS THE POINT: rebuild first, then check.
  T '  ...and the rebuild runs BEFORE the check' `
    ($chainSrc.IndexOf('audit-surface-staleness.ps1') -gt $chainSrc.IndexOf('build-cheapnow-data.ps1')) 'the check runs before the rebuild'

  # The two builders that used to write a .js file and stop must still splice.
  foreach ($pair in @(@('build-dinner-data.ps1','/*DIN-DATA*/'), @('build-stretcher-data.ps1','/*PSD-DATA*/'), @('build-cheapnow-data.ps1','/*CN-DATA*/'))) {
    $src = Get-Content (Join-Path $mp $pair[0]) -Raw -Encoding utf8
    T ("MUST FIRE  $($pair[0]) splices its payload into the tool rather than printing it for a human") `
      ($src.Contains($pair[1])) 'no splice - the live tool will drift again'
  }

  if ($bad -gt 0) { Write-Output "audit-surface-staleness SELF-TEST FAIL ($bad)"; exit 2 }
  Write-Output 'audit-surface-staleness SELF-TEST PASS'
  Write-GuardComplete -Name 'surface-staleness' -Summary 'selftest pass'
  exit 0
}

# ---- live sweep --------------------------------------------------------------------------------------
$manPath = Join-Path $mp 'pipeline\v2-perserving.json'
$dbPath  = Join-Path $mp 'recipes-db.json'
if (-not (Test-Path $manPath) -or -not (Test-Path $dbPath)) {
  Write-Output 'audit-surface-staleness: manifest or recipes-db missing - CANNOT EVALUATE'
  Write-GuardComplete -Name 'surface-staleness' -Summary 'could-not-evaluate no-manifest'
  exit 3
}
$manifest = @{}
foreach ($r in @((Get-Content $manPath -Raw -Encoding utf8 | ConvertFrom-Json))) { $manifest[[string]$r.slug] = [double]$r.cheapest_ps }
$catalog = @{}
$doc = (Get-Content $dbPath -Raw -Encoding utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
foreach ($r in @($doc.recipes)) { $catalog[[string]$r.slug] = [string]$r.name }
if ($manifest.Count -eq 0 -or $catalog.Count -eq 0) {
  Write-Output 'audit-surface-staleness: manifest or catalog read as empty - CANNOT EVALUATE'
  Write-GuardComplete -Name 'surface-staleness' -Summary 'could-not-evaluate empty-inputs'
  exit 3
}

# EACH SURFACE IS COMPARED AGAINST THE SOURCE IT IS BUILT FROM, WHICH IS NOT THE SAME SOURCE FOR ALL FOUR.
# A recipe carries four per-serving cost numbers on three different bases and they legitimately disagree
# (see the estate's cost-basis map). build-stretcher-data.ps1 is the documented mixed-basis tool: it takes
# per-serving from the manifest (CHEAPEST) but the batch figure it actually emits from
# recipes-db.cost_batch_true (EVERYDAY). Pointing this guard at the manifest for that surface produced 570
# findings on a surface that was, measured the same minute, current with its own source on 580 of 580 rows.
# That is a guard measuring basis rather than staleness, and it would have been a standing false alarm.
# The basis mismatch itself is real and is NOT this guard's call to fix: see the note printed at the end.
$batchRef = @{}
foreach ($r in @($doc.recipes)) {
  $sv = [int]$r.servings
  if ($sv -gt 0 -and $r.PSObject.Properties['cost_batch_true'] -and $r.cost_batch_true) {
    $batchRef[[string]$r.slug] = [double]$r.cost_batch_true / $sv
  }
}
$surfaces = @(
  @{ label = 'cheap-dinners';   kind = 'CN';  ref = $manifest; path = (Join-Path $repo 'site\tools\cheap-dinners-tool.html') },
  @{ label = 'dinner-tonight';  kind = 'DIN'; ref = $manifest; path = (Join-Path $repo 'site\tools\dinner-tonight-tool.html') },
  @{ label = 'payday-stretcher';kind = 'PSD'; ref = $batchRef; path = (Join-Path $repo 'site\tools\payday-stretcher-tool.html') }
)
$findings = @(); $unevaluated = @(); $summary = @()
foreach ($s in $surfaces) {
  if (-not (Test-Path $s.path)) { $unevaluated += ("{0}: source missing at {1}" -f $s.label, $s.path); continue }
  $rows = Get-SurfaceRows ([IO.File]::ReadAllText($s.path)) $s.kind
  if ($rows.Count -eq 0) { $unevaluated += ("{0}: parsed ZERO rows - the payload shape has changed and this surface is UNWATCHED" -f $s.label); continue }
  $f = @(Get-StalenessFindings $rows $s.ref $catalog $s.label)
  $findings += $f
  $summary += ("  {0,-18} rows={1,-4} findings={2}" -f $s.label, $rows.Count, $f.Count)
}

# THE HUB HAS NO LOCAL ARTIFACT. Its price lives only on the published page, and it is the one surface a
# reader actually reads a stale number off, so it is checked where it lives. Unreachable is exit 3.
if (-not $SkipHub) {
  try {
    $hubHtml = (Invoke-WebRequest -Uri 'https://www.thriftycrew.com/meal-prep-recipes/' -UseBasicParsing -TimeoutSec 45 -Headers @{'Cache-Control'='no-cache'}).Content
    $hubRows = Get-SurfaceRows $hubHtml 'HUB'
    if ($hubRows.Count -eq 0) { $unevaluated += 'hub: parsed ZERO cards off the live page - the card markup has changed and this surface is UNWATCHED' }
    else {
      $hf = @(Get-StalenessFindings $hubRows $manifest $catalog 'hub')
      $findings += $hf
      $summary += ("  {0,-18} rows={1,-4} findings={2}" -f 'hub (live)', $hubRows.Count, $hf.Count)
    }
  } catch {
    $unevaluated += ('hub: could not fetch the live page (' + $_.Exception.Message + ')')
  }
}

$summary | ForEach-Object { Write-Output $_ }
if ($unevaluated.Count) {
  $unevaluated | ForEach-Object { Write-Output ('  ! ' + $_) }
  Write-Output ("audit-surface-staleness: {0} surface(s) COULD NOT BE EVALUATED" -f $unevaluated.Count)
  Write-GuardComplete -Name 'surface-staleness' -Summary ("could-not-evaluate " + $unevaluated.Count)
  exit 3
}
if ($findings.Count) {
  $show = if ($ShowAll) { $findings } else { $findings | Select-Object -First 25 }
  $show | ForEach-Object { Write-Output ('  ! ' + $_) }
  if (-not $ShowAll -and $findings.Count -gt 25) { Write-Output ("  ... and {0} more (-ShowAll for the list)" -f ($findings.Count - 25)) }
  Write-Output ("audit-surface-staleness: {0} finding(s) - a reader-facing price surface disagrees with the manifest" -f $findings.Count)
  Write-GuardComplete -Name 'surface-staleness' -Summary ("findings " + $findings.Count)
  exit 1
}
Write-Output 'audit-surface-staleness: all four price surfaces agree with the source they are built from'
Write-Output '  note: payday-stretcher is compared on the EVERYDAY basis (recipes-db.cost_batch_true), which is'
Write-Output '        what its builder emits. The live tool then hydrates week_cost from the feed, which is the'
Write-Output '        CHEAPEST basis, so its baked fallback and its hydrated value are on different bases. That is'
Write-Output '        a pre-existing basis question for a human, not staleness, and this guard does not rule on it.'
Write-GuardComplete -Name 'surface-staleness' -Summary 'clean'
exit 0
