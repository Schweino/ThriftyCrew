<#
  regular-fileset-lib.ps1 - THE definition of "which out\regular files does the board actually price from".

  *** WHY THIS FILE EXISTS ***
  compare-deals.ps1 owned this rule and guards.ps1 had its own, simpler one: "newest file per store". Those
  two answers differ for exactly one store, and it is the biggest one on the board.

  Walmart has no weekly ad cycle, so a partial daily capture must UNION with recent files instead of replacing
  them (see the EVERYDAY-ONLY note below). The engine therefore prices Walmart from every file inside the policy's 90-day (was 14-day)
  window; guards.ps1 opened only the newest. Measured on 2026-07-29: 332 live Walmart board cells came from
  files guard 5 (multipack) and guard 10 (never publish the regular price) never opened. Those two guards exist
  to stop a 2x pack price and a price the store is not charging, and roughly a third of the Walmart cells they
  were supposed to cover were structurally out of reach - a bad row in ANY capture older than today was live on
  the board and unreachable by the gates written to catch it.

  A guard must iterate the SAME file set the engine priced from, or it is guarding a different board than the
  one that ships. Both now call this.

  NOT GUARD 9. Guard 9 measures how FRESH the newest capture is; newest-per-store is the correct question
  there, and widening it would make a store look fresher than it is by averaging in older files. Guard 9
  deliberately keeps its own newest-only lookup.

  *** NO param() BLOCK IN THIS FILE, DELIBERATELY ***
  Dot-sourcing a script runs its param() block in the CALLER's scope. capture-lib.ps1 learned this the hard way
  on 2026-07-29: a `param([switch]$SelfTest)` in a shared lib silently reset every builder's own $SelfTest to
  $false. A shared library must not declare parameters at all.
#>

# EVERYDAY-ONLY STORES: out\regular stores with no weekly ad cycle, where it is safe AND REQUIRED to union
# across recent captures rather than let the newest file win outright. A throttled/bot-walled Walmart pull
# returns a fraction of the catalogue, and under newest-file-wins that partial REPLACED the full board.
# Deliberately distinct name so dot-sourcing cannot collide with a caller's own variable.
$script:REGFILESET_EVERYDAY_ONLY = @('walmart')

function Get-EverydayOnlyStores { return @($script:REGFILESET_EVERYDAY_ONLY) }

# THE UNION WINDOW, SINGLE-SOURCED. compare-deals takes it as -WalmartMaxAgeDays (default 14) and guards.ps1
# repeated the literal 14 next to it. Two copies of the window length is the same class of bug this file was
# written to kill, one size smaller: nothing on either side notices when one of them moves. compare-deals'
# -SelfTest asserts its own param default still equals this, and guards.ps1 runs that self-test as a BLOCKING
# invariant (guard 0b), so the drift cannot reach a publish.
# 2026-08-20: 14 -> 90, to match the capture policy. Under the quarterly rotation a term's
# next scheduled capture is ~90 days out, so a 14-day window expires nearly every row BEFORE
# the rotation can come back to it - capture-policy.ps1 puts that at ~85% of the catalog, and
# it was already live: the Walmart fullpull watch had 471 of 471 attributed cells (100%) due
# to leave this window on 2026-08-21. The number is the CAPTURE POLICY's MaxCarryDays and may
# not be edited here alone; capture-policy.ps1 owns it and compare-deals' -SelfTest asserts
# the two still agree (Test-PolicyWindowAgreement below).
$script:REGFILESET_UNION_DAYS = 90

# Read the policy's own number. This used to scrape capture-policy.ps1 AS TEXT, because that
# file declared a param() block and could not be dot-sourced from here without its parameters
# landing in every caller's scope - the capture-lib.ps1 bug of 2026-07-29 that the header above
# forbids. On 2026-08-21 the policy was split: the constants and functions moved to the
# paramless capture-policy-lib.ps1, so the reason for the scrape is gone and the scrape itself
# is now the fragile part. It reads the file it is POINTED at, and a constant that moves house
# turns the guard silently blind - which is exactly what happened the moment the split landed:
# this returned $null and the drift check reported "capture-policy says <nothing>".
#
# So: ask the library, and keep a text fallback ONLY for the case where the library is missing
# entirely. Returns $null when the number genuinely cannot be established, so an unknown reports
# as unknown rather than silently asserting agreement.
function Get-PolicyCarryDaysFromText {
  $lib = Join-Path $PSScriptRoot 'capture-policy-lib.ps1'
  if (Test-Path $lib) {
    try {
      if (-not (Get-Command Get-PolicyMaxCarryDays -ErrorAction SilentlyContinue)) { . $lib }
      $v = Get-PolicyMaxCarryDays
      if ($v) { return [int]$v }
    } catch { }
    # The library exists but would not answer: fall back to reading its text, still pointed at
    # the file that actually holds the constant today.
    $m = [regex]::Match([IO.File]::ReadAllText($lib), '(?m)^\s*\$script:MaxCarryDays\s*=\s*(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
  }
  return $null
}
function Get-RegularUnionDays { return $script:REGFILESET_UNION_DAYS }

function Resolve-BoardAsOf($boardFileObjs, [datetime]$wallClock) {
  <#
    THE AS-OF THE ENGINE ACTUALLY USED, read off the artifact instead of re-derived from the clock.
    compare-deals resolves the union against $today = $ads.today, and it NAMES the board it writes with that
    same value (comparison-<$today>.json), so the board's own filename IS the engine's as-of, exactly.
    guards.ps1's first version of this used (Get-Date).Date. Those two differ on any run that builds or
    re-checks a board on a LATER calendar day than the ads it was built from - which is what the repair /
    triage loop does every time it fixes a rule and rebuilds yesterday's board this morning.
    MEASURED 2026-07-30 08:19: comparison-2026-07-29.json was rebuilt from ads-2026-07-29, so the engine's
    as-of was 07-29 and guards' was 07-30, and walmart-regular-2026-07-15.json - 711 rows, 20 of them
    pack-shaped, 323 of them carrying current_price, every one priced into that board - fell outside guard 5
    and guard 10. That is the item-9 hole, reopened exactly one day wide by the line that closed it.
    No board on disk -> the wall clock. That state is not silently accepted: guard 12 hard-fails it on its own.
  #>
  $b = $boardFileObjs |
    Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } |
    Sort-Object Name -Descending | Select-Object -First 1
  if (-not $b) { return $wallClock }
  # [regex]::Match into a local, never -match: $Matches is global and the next -match anywhere clobbers it.
  $m = [regex]::Match($b.BaseName, '(\d{4}-\d{2}-\d{2})$')
  if (-not $m.Success) { return $wallClock }
  return [datetime]$m.Groups[1].Value
}

function Select-EngineRegularFiles([string]$outDir, [datetime]$wallClock) {
  <#
    THE ONE production entry point guards.ps1 calls: the out\regular files the board ON DISK was priced from.
    Deliberately a single function taking $outDir, so the self-test can point it at a synthetic tree and
    exercise the REAL path - a fixture that tested Resolve-BoardAsOf and Select-RegularFileSet separately
    would still pass on the day the caller stopped using one of them.
    compare-deals does NOT call this, on purpose: its as-of is $ads.today, the source of truth, and an engine
    that resolved its own inputs from the board it is about to overwrite would have no source of truth left.
  #>
  $boards = Get-ChildItem (Join-Path $outDir 'comparison-*.json') -ErrorAction SilentlyContinue
  $asof = Resolve-BoardAsOf $boards $wallClock
  $regs = Get-ChildItem (Join-Path $outDir 'regular\*-regular-*.json') -ErrorAction SilentlyContinue
  return @(Select-RegularFileSet $regs $asof (Get-RegularUnionDays))
}

function Select-RegularFileSet($fileObjs, [datetime]$asof, [int]$unionMaxAgeDays) {
  <#
    Given candidate out\regular file objects, return the ones the board prices from:
      - an EVERYDAY-ONLY store  -> every dated capture within $unionMaxAgeDays of $asof (the union)
      - every other store       -> the newest dated capture only
    The name filter is load-bearing: '*-regular-*.json' also matches things like
    'family-fare-regular-<date>.PARTIAL.json', and a non-canonical name can outsort real data in a
    newest-by-name lookup.
  #>
  $everyday = Get-EverydayOnlyStores
  $fileObjs |
    Where-Object { $_.BaseName -match '^[a-z0-9-]+-regular-\d{4}-\d{2}-\d{2}$' } |
    Group-Object { ($_.BaseName -replace '-regular-.*$','') } |
    ForEach-Object {
      $grp = $_.Group | Sort-Object Name -Descending
      if ($everyday -contains $_.Name) {
        $grp | Where-Object {
          $m = [regex]::Match($_.BaseName, '(\d{4}-\d{2}-\d{2})$')
          $m.Success -and [math]::Abs(([datetime]$m.Groups[1].Value - $asof).TotalDays) -le $unionMaxAgeDays
        }
      } else {
        $grp | Select-Object -First 1
      }
    }
}

function Select-EngineSamsFiles([string]$outDir, [datetime]$wallClock) {
  <#
    SAM'S HAS NO out\regular FILE AT ALL, and every guard that assumes one is reading a board that does not
    exist. The club catalogue is CAPTCHA-walled, so Sam's is captured in partial slices into
    out\sams\sams-deals-*.json, and compare-deals unions every slice inside the carry window (its
    -SamsMaxAgeDays, the same 90 days as Get-RegularUnionDays) because any one slice covers only the
    categories that run got through before the wall. compare-deals.ps1 states this outright: "Sam's has no
    out\regular\ file at all: its prices come only from out\sams\sams-deals-*.json".

    MEASURED 2026-08-30. generate-board-overrides' board-confirmed-fresh gate kept its own private map that
    sent Sam's to out\regular\sams-regular-*.json. Two orphan files from July/August still sit there, so the
    gate loaded 60 rows, found nothing, raised no alarm (its zero-rows warning is estate-wide, and the other
    six stores had rows), and FAILED OPEN for every Sam's cell. That is how frozen-fruit got pinned to
    "Member's Mark Triple Berry Blend, 64 oz." at 16.34c/oz over the board's own
    "Member's Mark Natural Sliced Strawberries, 4 lbs." at 12.47c/oz - two different products sitting side by
    side in the SAME capture (sams-deals-2026-08-15), the cheaper of which the board had correctly chosen.
    Pointed here, the gate finds the board's exact item at its exact price and refuses the pin.

    Newest-first, like the out\regular sets, so a caller that wants the freshest row for a name gets it first.
  #>
  $boards = Get-ChildItem (Join-Path $outDir 'comparison-*.json') -ErrorAction SilentlyContinue
  $asof = Resolve-BoardAsOf $boards $wallClock
  $win  = Get-RegularUnionDays
  @(Get-ChildItem (Join-Path $outDir 'sams\sams-deals-*.json') -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match '^sams-deals-\d{4}-\d{2}-\d{2}$' } |
    Where-Object {
      $m = [regex]::Match($_.BaseName, '(\d{4}-\d{2}-\d{2})$')
      $m.Success -and [math]::Abs(([datetime]$m.Groups[1].Value - $asof).TotalDays) -le $win
    } | Sort-Object Name -Descending)
}
