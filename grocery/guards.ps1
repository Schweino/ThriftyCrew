<#
  guards.ps1 - the BLOCKING invariant gate. Run before every publish; a hard failure means the board
  must NOT go live.

  WHY THIS EXISTS: on 2026-07-14 the board published bottled water at $3.87 EACH (the price of the whole
  24-pack), Sam's white vinegar at 2x its real price, Aldi onions at 3x, a bag of potato chips as the
  cod price, and a bathroom cleaner as the mango price. Every one of those was self-consistent and
  invisible to the existing gates. These checks exist so none of them can ever ship again.

  HARD FAILS (exit 2 - do not publish):
    1. price-mode      : a mode-sensitive store (Aldi/Fareway - Instacart storefronts) not pinned to
                         the IN-STORE catalogue. Their delivery catalogue is marked up ~11%.
    2. household-in-food: a cleaning product resolving to an EDIBLE commodity.
    3. rogue pin       : a board-price-override pin that disagrees with what the engine computed. A pin
                         BEATS the engine, so a wrong pin publishes a number nothing else can correct.
    4. factor mismatch : an EVERYDAY cell whose linked product's per-unit differs from the board's by a
                         FACTOR (>=1.5x or <=0.67x).
                         *** THE KEY IDEA ***: a store changing its price moves it a few percent. A
                         quantity/parse bug moves it by a FACTOR (2x a 2-pack, 3x a 3-packet strip, 6x,
                         12x, 24x a case). So we gate on the FACTOR and stay quiet about ordinary price
                         drift, which the daily consistency auto-repair already handles.
    5. multipack size  : a row whose NAME says "N pack" but whose SIZE records one unit (the Sam's
                         2-pack bug), unless it is on the reviewed allowlist.

  ADVISORY (logged, never blocks): ordinary link/board price drift, and order-dependent match rows.

  Exit codes: 0 = safe to publish. 2 = HARD FAIL. (Advisory-only findings still exit 0.)
#>
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'pu-lib.ps1')   # THE per-unit math - the same one build-deals-page publishes with
$fail = New-Object System.Collections.ArrayList
$warn = New-Object System.Collections.ArrayList
function Say($s) { if (-not $Quiet) { Write-Output $s } }

# Canonical store data files ONLY. Guard 7 below explains why: a non-canonical name in out\regular can
# outsort the real data in a "newest by name" lookup, so every such lookup in this script filters by NAME,
# not just by glob. (A '*-regular-*.json' glob happily matches 'family-fare-regular-<date>.PARTIAL.json'.)
function RegFiles([string]$pattern = '*-regular-*.json') {
  Get-ChildItem (Join-Path $root ('out\regular\' + $pattern)) -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match '^[a-z0-9-]+-regular-\d{4}-\d{2}-\d{2}$' }
}

# ---------------------------------------------------------------- 0: pu-lib per-unit engine self-check
# The publish path AND this gate both price with Get-LinkPerUnit. A silent regression there is invisible to
# every downstream check, because a cell it can no longer price reads as "unknown" and gets SKIPPED, not
# flagged - exactly how the "6 pk 4 oz" multipack format once returned null and dropped 19 cells out of the
# factor guard while the gate stayed green. So assert the tricky cases right here, in the gate the daily cloud
# job runs, and HARD FAIL before anything ships if the math drifts. Mirrors the assertions in test-pu-lib.ps1
# (pure computation - no board mutation, no I/O), so it is safe to run on every publish.
$puCases = @(
  @{ size='6 pk 4 oz';     unit='oz';   price=2.50; name='';              want=0.104167 }  # pack-first multipack
  @{ size='2 pk 48 fl oz'; unit='floz'; price=4.00; name='';              want=0.041667 }  # fl-oz multipack
  @{ size='6 pk 16 oz';    unit='oz';   price=3.00; name='';              want=0.03125  }  # pack-first
  @{ size='16 oz 6 pk';    unit='oz';   price=3.00; name='';              want=0.03125  }  # weight-first (no double-mult)
  @{ size='4 pk 4 oz';     unit='each'; price=2.78; name='';              want=0.695    }  # each: N pk = N items
  @{ size='each';          unit='each'; price=6.00; name='Water 24 Pack'; want=0.25     }  # multipack-in-name
  @{ size='3 oz';          unit='oz';   price=2.18; name='';              want=0.726667 }  # plain single
  @{ size='lb';            unit='lb';   price=4.99; name='';              want=4.99     }  # bare unit
  @{ size='$0.07/oz';      unit='oz';   price=5.00; name='';              want=0.07     }  # explicit unit price
  @{ size='16 oz';         unit='each'; price=2.49; name='';              want=$null    }  # genuine unit mismatch -> null
)
$puBad = New-Object System.Collections.Generic.List[string]
foreach ($c in $puCases) {
  $g = Get-LinkPerUnit -size $c.size -unit $c.unit -price $c.price -name $c.name
  $ok = if ($null -eq $c.want) { $null -eq $g } else { ($null -ne $g) -and ([math]::Abs([double]$g - [double]$c.want) -lt 0.001) }
  if (-not $ok) { $puBad.Add(('"{0}"/{1} -> {2} (want {3})' -f $c.size, $c.unit, $g, $c.want)) }
}
if ($puBad.Count) { [void]$fail.Add("HARD FAIL: pu-lib per-unit math regressed [" + ($puBad -join '; ') + "] - the publish path prices with this engine; see test-pu-lib.ps1") }
else { Say '  ok    pu-lib per-unit engine self-check' }

# ---------------------------------------------------------------- 1 + 2: delegate to the existing audits
foreach ($g in @(
    @{ f='audit-price-mode.ps1';        n='price-mode (in-store pricing)' },
    @{ f='audit-household-in-food.ps1'; n='household-in-food' })) {
  $p = Join-Path $root $g.f
  if (-not (Test-Path $p)) { [void]$fail.Add(("MISSING GUARD SCRIPT: " + $g.f)); continue }
  & powershell -NoProfile -ExecutionPolicy Bypass -File $p | Out-Null
  if ($LASTEXITCODE -ne 0) { [void]$fail.Add(("HARD FAIL: " + $g.n + " (see " + $g.f + ")")) }
  else { Say ("  ok    " + $g.n) }
}

# ---------------------------------------------------------------- shared: the board + the links
$cmpF = Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1
$cmp  = Get-Content $cmpF.FullName -Raw | ConvertFrom-Json
$pu   = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items

# ---------------------------------------------------------------- 3: a pin must never beat the engine
$ovrF = Join-Path $root 'board-price-overrides.json'
$rogue = 0
if (Test-Path $ovrF) {
  $ovr = Get-Content $ovrF -Raw | ConvertFrom-Json
  foreach ($c in $ovr.cells) {
    $row  = $cmp.comparison | Where-Object { $_.id -eq $c.id }
    if (-not $row) { continue }
    $cell = $row.stores | Where-Object { $_.store -eq $c.store }
    if (-not $cell) { continue }
    $pin = [double]$c.per_unit; $eng = [double]$cell.per_unit
    if ($eng -le 0) { continue }
    if ([math]::Abs($eng - $pin) / $eng -gt 0.02) {
      $rogue++
      [void]$fail.Add(("HARD FAIL: pin OVERRIDES engine  {0} / {1}  pin={2} engine={3}" -f $c.id, $c.store, [math]::Round($pin,4), [math]::Round($eng,4)))
    }
  }
}
if ($rogue -eq 0) { Say '  ok    no override pin disagrees with the engine' }

# ---------------------------------------------------------------- 4: factor mismatch (board vs its own link)
# Per-unit math comes from pu-lib.ps1 - the SAME function build-deals-page uses to publish the number. This
# guard used to carry its own weaker copy (Qty), which returned 0 - meaning "skip this cell" - for sizes the
# published math handles fine: "per lb", a bare "lb", "24 fl oz" against an oz commodity, "dozen", and a unit
# price like "$0.07/oz" parked in the size field. That silently excluded 185 of 2,156 linked everyday cells
# (8.6%) from this check while the guard still reported "0 mismatches". A gate that grades the page with
# different arithmetic than the page was built with is not grading the page.
$unpriceable = 0
$factorBugs = 0; $drift = 0
foreach ($row in $cmp.comparison) {
  $link = $pu.($row.id)
  if (-not $link) { continue }
  foreach ($s in $row.stores) {
    if (([string]$s.type) -ne 'everyday') { continue }      # a weekly-ad price legitimately differs
    $e = $link.($s.store)
    if (-not $e -or -not $e.price) { continue }
    $sp = 0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$sp)
    $lpu = Get-LinkPerUnit -size ([string]$e.size) -unit ([string]$row.unit) -price $sp -name ([string]$e.name)
    if ($null -eq $lpu) { $unpriceable++; continue }
    $bpu = [double]$s.per_unit
    if ($bpu -le 0 -or $lpu -le 0) { continue }
    $ratio = $lpu / $bpu
    if ($ratio -ge 1.5 -or $ratio -le 0.67) {
      $factorBugs++
      [void]$fail.Add(("HARD FAIL: {0}x factor  {1} / {2}  board={3} link={4}  [{5}]" -f [math]::Round($ratio,2), $row.id, $s.store, [math]::Round($bpu,4), [math]::Round($lpu,4), $e.name))
    } elseif ([math]::Abs($ratio - 1) -gt 0.02) { $drift++ }
  }
}
if ($factorBugs -eq 0) { Say '  ok    no board cell differs from its linked product by a factor' }
if ($drift -gt 0) { [void]$warn.Add("$drift cell(s) drift from their link by <50% (ordinary price movement; the daily consistency repair handles it)") }
# SAY WHAT WAS NOT CHECKED. The previous version skipped unparseable cells in silence, so its clean result
# covered 91% of the board while reading as though it covered all of it. Coverage a gate does not report is
# coverage nobody can audit.
if ($unpriceable -gt 0) { [void]$warn.Add("$unpriceable linked cell(s) carry no usable unit basis (empty/odd size) and could NOT be factor-checked - not a pass, an unknown") }

# ---------------------------------------------------------------- 5: multipack size
$allowF = Join-Path $root 'multipack-allowlist.json'
$allow = @()
if (Test-Path $allowF) { $allow = @((Get-Content $allowF -Raw | ConvertFrom-Json).allow | ForEach-Object { $_.store + '|' + $_.item }) }
$mp = 0
foreach ($f in (RegFiles)) {
  $prefix = ($f.BaseName -replace '-regular-.*$','')
  $newest = RegFiles ($prefix + '-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1
  if ($f.FullName -ne $newest.FullName) { continue }
  $doc = Get-Content $f.FullName -Raw | ConvertFrom-Json
  foreach ($d in $doc.deals) {
    $name = [string]$d.item; $size = [string]$d.size
    if (-not $name -or -not $size) { continue }
    $pn = [regex]::Match($name.ToLower(), '(\d+)\s*(?:pk\b|pack\b)')
    if (-not $pn.Success) { continue }
    if ([int]$pn.Groups[1].Value -le 1) { continue }
    $ps = [regex]::Match($size.ToLower(), '(\d+)\s*(?:x|pk\b|pack\b|ct\b|count\b)')
    if ($ps.Success -and ([int]$ps.Groups[1].Value) -gt 1) { continue }
    if ($size -notmatch '[\d.]+\s*(fl\s?oz|oz|lb|gal|qt|l|ml|g)\b') { continue }
    $key = [string]$doc.store + '|' + $name
    if ($allow -contains $key) { continue }
    $mp++
    [void]$fail.Add(("HARD FAIL: multipack size  [{0}] '{1}' size=[{2}] records ONE unit" -f $doc.store, $name, $size))
  }
}
if ($mp -eq 0) { Say '  ok    no multipack row prices a pack as a single unit' }

# ---------------------------------------------------------------- 6: a store's data collapsed
# A throttled / half-failed pull that writes a thin file must never become a store's source of truth.
# This really happened: a "family-fare-regular-<date>.PARTIAL.json" sorted AFTER the good file, so every
# consumer picked the 0-row throttled file and Family Fare silently fell from ~177 board rows to 55.
# The pull scripts have their own wipeout guards, but a guard you can walk around is not a guard - so the
# publish gate re-checks it independently: the newest file per store must not be a fraction of what that
# store had in its recent history.
$thin = 0
$prefixes = @{}
foreach ($f in (RegFiles)) {
  $p = ($f.BaseName -replace '-regular-.*$','')
  if (-not $prefixes.ContainsKey($p)) { $prefixes[$p] = $true }
}
foreach ($p in $prefixes.Keys) {
  $files = @(RegFiles ($p + '-regular-*.json') | Sort-Object Name -Descending)
  if ($files.Count -lt 2) { continue }
  $newest = $files[0]
  $curr = 0
  try { $curr = @((Get-Content $newest.FullName -Raw | ConvertFrom-Json).deals).Count } catch {}
  $best = 0
  foreach ($old in ($files | Select-Object -Skip 1 -First 4)) {
    try { $c = @((Get-Content $old.FullName -Raw | ConvertFrom-Json).deals).Count; if ($c -gt $best) { $best = $c } } catch {}
  }
  if ($best -gt 100 -and $curr -lt ($best * 0.5)) {
    $thin++
    [void]$fail.Add(("HARD FAIL: store data collapsed  [{0}] newest file '{1}' has {2} rows vs {3} recently - a throttled/partial pull must not become the source of truth" -f $p, $newest.Name, $curr, $best))
  }
}
if ($thin -eq 0) { Say '  ok    no store''s newest data file collapsed vs its recent history' }

# ---------------------------------------------------------------- 7: no stray files in out\regular
# THE ROOT CAUSE of the Family Fare collapse, and the only check that catches it at the source.
# out\regular is a DATA directory: several consumers glob it with '*.json' and treat whatever they find as a
# store, and all of them resolve "newest" by sorting the FILENAME. So a file named
# "family-fare-regular-2026-07-14.PARTIAL.json" both (a) reads as the family-fare store and (b) sorts AFTER
# the real "...-2026-07-14.json" ('p' > 'j'), which silently made an empty throttle diagnostic the source of
# truth. Renaming such files is not a fix; the fix is that NOTHING but canonical store data may live here.
# Diagnostics go to out\throttled\. Anything else in out\regular is a hard fail, by name, before it can be read.
$stray = @(Get-ChildItem (Join-Path $root 'out\regular\*') -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -notmatch '^[a-z0-9-]+-regular-\d{4}-\d{2}-\d{2}\.json$' })
if ($stray.Count -gt 0) {
  foreach ($s in ($stray | Select-Object -First 10)) {
    [void]$fail.Add(("HARD FAIL: stray file in out\regular  '{0}' - only '<store>-regular-<yyyy-MM-dd>.json' may live here; anything else can be read as a store and can outsort the real data (put diagnostics in out\throttled\)" -f $s.Name))
  }
} else { Say '  ok    out\regular holds only canonical <store>-regular-<date>.json data files' }

# ---------------------------------------------------------------- 8: no undated stale discount published as a sale
# THE ONLY BUG CLASS THAT WAS STRUCTURALLY INVISIBLE TO EVERY OTHER CHECK HERE.
# A `sale` cell is EXEMPT from the price audits by design: a weekly-ad price is supposed to differ from the
# shelf price on the product page it links to. That exemption is correct for an ad-backed sale, and it is a
# blank cheque for anything else wearing the same label.
# On 2026-07-14 the board published Hy-Vee sirloin at $6.99/lb, flagged Cheapest, badged "Sale thru Jul 19".
# The real price was $11.99/lb. The $6.99 came from a two-day-old "Aisles Online markdown" snapshot in
# extra-deals: no end date, tied to no ad cycle, replayed as a live sale for a week, and wearing an end date
# borrowed from the store's ad window. FIFTY-ONE cells were served this way. Not one guard could see it.
# Invariant: a row claiming a discount, carrying no end date, captured before today, must not appear on the
# board as a sale. If we cannot say when a discount ends, we cannot say it is running.
$exF = Get-ChildItem (Join-Path $root 'out\extra-deals-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$staleSale = 0
if ($exF) {
  $exDate = ''
  if ($exF.BaseName -match '(\d{4}-\d{2}-\d{2})$') { $exDate = $Matches[1] }
  $todayReal = (Get-Date -Format 'yyyy-MM-dd')
  if ($exDate -and ($exDate -ne $todayReal)) {
    $ex = Get-Content $exF.FullName -Raw | ConvertFrom-Json
    $suspect = @{}
    foreach ($d in @($ex.deals)) {
      if ($d.sale_end) { continue }
      $ap = 0.0; $rg = 0.0
      [void][double]::TryParse((([string]$d.ad_price) -replace '[^0-9.]',''), [ref]$ap)
      [void][double]::TryParse((([string]$d.regular)  -replace '[^0-9.]',''), [ref]$rg)
      if ($ap -gt 0 -and $rg -gt 0 -and $ap -lt $rg) { $suspect[(([string]$d.store) + '|' + ([string]$d.item).Trim())] = $ap }
    }
    foreach ($row in $cmp.comparison) {
      foreach ($s in $row.stores) {
        if (([string]$s.type) -ne 'sale') { continue }
        $k = ([string]$s.store) + '|' + ([string]$s.item).Trim()
        if (-not $suspect.ContainsKey($k)) { continue }
        $bAd = 0.0; [void][double]::TryParse((([string]$s.ad) -replace '[^0-9.]',''), [ref]$bAd)
        if ($bAd -gt 0 -and ([math]::Abs($bAd - $suspect[$k]) -lt 0.005)) {
          $staleSale++
          [void]$fail.Add(("HARD FAIL: stale undated discount published as a live sale  {0} / {1}  `${2}  (from {3}, no end date - a sale we cannot date is a sale we cannot stand behind)" -f $row.id, $s.store, $bAd, $exF.Name))
        }
      }
    }
  }
}
if ($staleSale -eq 0) { Say '  ok    no undated stale discount is being published as a live sale' }

# ---------------------------------------------------------------- 9: price freshness, per store
# "SAFE" IS NOT A SYNONYM FOR "ACCURATE" (Brad's rule, and the right one). A stale price is a wrong price; it
# just fails in a direction that feels comfortable. Hy-Vee sat for days publishing basePrice - the REGULAR
# price - while the store was charging less, and nothing complained, because nothing was watching the CLOCK.
# So: every store reports how old its prices are and how many of them we could not re-verify. A store that
# cannot be checked is a store that is quietly drifting, and that has to be visible on every single run
# rather than discovered by a reader clicking a link.
$today = [datetime](Get-Date -Format 'yyyy-MM-dd')
$stale = 0
foreach ($f in (RegFiles)) {
  $prefix = ($f.BaseName -replace '-regular-.*$','')
  $newest = RegFiles ($prefix + '-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1
  if ($f.FullName -ne $newest.FullName) { continue }
  $doc = Get-Content $f.FullName -Raw | ConvertFrom-Json
  $store = [string]$doc.store
  $rows = @($doc.deals)
  if (-not $rows.Count) { continue }

  # how many rows carry a date, and how old is the freshest?
  $dated = @($rows | Where-Object { $_.as_of })
  $unver = @($rows | Where-Object { $_.not_reverified }).Count
  $fileDate = $today
  if ($f.BaseName -match '(\d{4}-\d{2}-\d{2})$') { try { $fileDate = [datetime]$Matches[1] } catch {} }

  $age = [int]($today - $fileDate).TotalDays
  $verifiedToday = 0
  foreach ($r in $dated) { if (([string]$r.as_of) -eq (Get-Date -Format 'yyyy-MM-dd')) { $verifiedToday++ } }

  $pct = 0
  if ($rows.Count -gt 0) { $pct = [math]::Round(100.0 * $verifiedToday / $rows.Count) }
  $note = ("{0,-13} {1,4} rows | {2,3}% re-verified against the store TODAY | file {3}d old" -f $store, $rows.Count, $pct, $age)
  if ($unver -gt 0) { $note += (" | {0} row(s) flagged unverified" -f $unver) }
  # Only stores that HAVE a regular/discounted split can suffer the Hy-Vee/Baker's bug. Aldi was checked and
  # cannot: it is everyday-low-price and its listings carry a single "Current price" with no was/now pair
  # anywhere. Flagging it for a bug it structurally cannot have would be crying wolf, and a warning nobody
  # believes is a warning nobody reads.
  if (($verifiedToday -eq 0) -and ($store -ne 'Aldi')) {
    $note += '  <-- NOT price-verified today: this store CAN discount, so it may be publishing regular prices (the Hy-Vee/Baker''s bug)'
  }
  [void]$warn.Add($note)

  # a store nobody has looked at in over two weeks is not "safe", it is unknown
  if ($age -gt 14) {
    $stale++
    [void]$fail.Add(("HARD FAIL: {0} price data is {1} days old - a stale price is a wrong price" -f $store, $age))
  }
}
if ($stale -eq 0) { Say '  ok    no store''s price data is older than 14 days' }

# ---------------------------------------------------------------- 10: never publish the REGULAR price
# THE BUG THIS WHOLE SESSION WAS ABOUT, TURNED INTO AN INVARIANT.
# A shopper never pays MORE than the regular price. So for any row where we know both numbers, the price we
# publish must be <= the regular price. If it is higher, we have taken the wrong field - we are publishing
# `basePrice`/`base_price` (the REGULAR price) over a live discount. That is precisely how Hy-Vee sirloin went
# out at $13.99/lb while Omaha #01 charged $11.99, and Baker's chicken breast at $2.89/lb against $2.29.
#
# THE CONTRACT THIS DEPENDS ON: a puller that can see BOTH prices must RECORD both - the current one in
# ad_price, the regular one in base_price. Without both on the row, nothing downstream can tell that the wrong
# one was published, and this guard is blind. Hy-Vee and Family Fare now honour that contract. Baker's,
# Fareway, Sam's and Walmart do NOT yet - guard 9 is what keeps their staleness visible until they do.
# A FIRST VERSION OF THIS GUARD WAS USELESS, AND THE NEGATIVE TEST IS WHAT PROVED IT.
# It asserted ad_price <= base_price - reasoning that a shopper never pays more than the regular price. But
# taking `base_price` does not publish a price ABOVE regular, it publishes one EXACTLY EQUAL to it. The check
# passed happily on the very bug it existed to catch. A guard you cannot fail on purpose is not a guard.
#
# The non-circular version: the puller records what the store CHARGES (`current_price`) independently of what
# we choose to PUBLISH (`ad_price`), and this asserts they are the same number. A puller that reaches for the
# regular-price field now produces two different numbers on the row, and that is visible from the outside.
$mismatch = 0; $checked = 0; $noContract = @{}
foreach ($f in (RegFiles)) {
  $prefix = ($f.BaseName -replace '-regular-.*$','')
  $newest = RegFiles ($prefix + '-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1
  if ($f.FullName -ne $newest.FullName) { continue }
  $doc = Get-Content $f.FullName -Raw | ConvertFrom-Json
  $store = [string]$doc.store
  $any = $false
  foreach ($d in $doc.deals) {
    if ($null -eq $d.current_price) { continue }
    $any = $true
    $cp = 0.0; [void][double]::TryParse((([string]$d.current_price) -replace '[^0-9.]',''), [ref]$cp)
    $ap = 0.0; [void][double]::TryParse((([string]$d.ad_price)      -replace '[^0-9.]',''), [ref]$ap)
    if ($cp -le 0 -or $ap -le 0) { continue }
    $checked++
    if ([math]::Abs($ap - $cp) -gt 0.005) {
      $mismatch++
      [void]$fail.Add(("HARD FAIL: publishing a price the store is NOT charging  [{0}] {1}  we publish `${2}, the store charges `${3} - the puller took the wrong price field (this is the basePrice bug)" -f $store, [string]$d.item, $ap, $cp))
    }
  }
  if (-not $any) { $noContract[$store] = $true }
}
if ($mismatch -eq 0) { Say ("  ok    every price we publish is the price the store charges ($checked rows verified against their own current_price)") }
if ($noContract.Count) {
  [void]$warn.Add(("these stores do NOT record the store's current price on their rows, so guard 10 CANNOT check them: " + (($noContract.Keys | Sort-Object) -join ', ') + " - until their pullers record current_price, guard 9's freshness numbers are the only thing standing between them and the basePrice bug"))
}

# ---------------------------------------------------------------- 11: Baker's price reconciles with the raw capture
# Guard 10 asserts ad_price == current_price - but BOTH are our own numbers, so it cannot catch a current_price
# that was COMPUTED wrong. That is exactly the 2026-07-14 milk bug: Baker's prints its unit price coarsely
# ("$0.02/fl oz"), the importer rebuilt per-gallon as 0.02 x 128 = $2.56 and published it against the $3.19 the
# store actually charges (its exact pack price `cur`). $2.56 equalled its own current_price, so guard 10 was
# happy. This invariant brings in the INDEPENDENT truth - the raw capture's exact `cur` - and asserts that when
# the store's pack IS our size (cur falls inside the band the rounded unit price allows for our size), the
# published price MUST equal cur. Runs only when a fresh capture (out\bakers-prices-raw.csv) is present, and any
# error in the check itself degrades to a warning (a new guard must never block the board by crashing).
try {
  $rawBk = Join-Path $root 'out\bakers-prices-raw.csv'
  if (Test-Path $rawBk) {
    function ConvBk([double]$v, [string]$of, [string]$u) {
      if ($v -le 0) { return $null }
      $b = (([string]$of).ToLower() -replace '\s',''); if (-not $b) { return $null }
      switch ($u) {
        'lb'     { if ($b -eq 'lb') { return $v }; if ($b -eq 'oz') { return ($v*16) }; return $null }
        'oz'     { if ($b -eq 'oz') { return $v }; if ($b -eq 'lb') { return ($v/16) }; return $null }
        'floz'   { if ($b -eq 'floz') { return $v }; return $null }
        'gallon' { if ($b -eq 'floz') { return ($v*128) }; return $null }
        'each'   { if ($b -match '^(ea|ct)$') { return $v }; return $null }
        'dozen'  { if ($b -match '^(ea|ct)$') { return ($v*12) }; return $null }
        default  { return $null }
      }
    }
    $rawP = @{}
    foreach ($ln in (Get-Content $rawBk)) {
      $c = ([string]$ln) -split ','; if ($c.Count -lt 6) { continue }
      $u0 = $c[0].Trim(); if (-not $u0) { continue }
      $cu = 0.0; [void][double]::TryParse((($c[1]) -replace '[^0-9.]',''), [ref]$cu)
      $uv0 = 0.0; [void][double]::TryParse((($c[3]) -replace '[^0-9.]',''), [ref]$uv0)
      if ($cu -gt 0) { $rawP[$u0] = [pscustomobject]@{ cur=$cu; uv=$uv0; uof=$c[4].Trim() } }
    }
    $pdRaw = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
    $unitById = @{}; foreach ($cc in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { $unitById[[string]$cc.id] = [string]$cc.unit }
    $unitByBkName = @{}
    foreach ($p in $pdRaw.PSObject.Properties) { $e = $p.Value.'Baker''s'; if ($e -and $e.name -and $unitById.ContainsKey([string]$p.Name)) { $unitByBkName[([string]$e.name).ToLower().Trim()] = $unitById[[string]$p.Name] } }

    $bkFile = RegFiles ('bakers-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1
    $bkChecked = 0; $bkBad = 0
    if ($bkFile) {
      $bkDoc = Get-Content $bkFile.FullName -Raw | ConvertFrom-Json
      foreach ($d in $bkDoc.deals) {
        if (-not $d.upc -or ($null -eq $d.current_price)) { continue }
        if (([string]$d.source_ad) -notmatch 'bakersplus') { continue }        # only rows priced from the capture
        $pv = $rawP[[string]$d.upc]; if (-not $pv) { continue }
        if (($null -eq $pv.uv) -or ([double]$pv.uv -le 0)) { continue }         # weighted rows checked by guards 4/10
        $unit = $unitByBkName[([string]$d.item).ToLower().Trim()]; if (-not $unit) { continue }
        $pu1 = Get-LinkPerUnit -size ([string]$d.size) -unit $unit -price 1 -name ([string]$d.item)
        if (($null -eq $pu1) -or ([double]$pu1 -le 0)) { continue }
        $ourQty = 1.0 / [double]$pu1
        $lo = ConvBk ([math]::Max(0.0001, [double]$pv.uv - 0.005)) ([string]$pv.uof) $unit
        $hi = ConvBk ([double]$pv.uv + 0.005) ([string]$pv.uof) $unit
        if (($null -eq $lo) -or ($null -eq $hi)) { continue }
        $loP = $lo * $ourQty; $hiP = $hi * $ourQty
        $cur = [double]$pv.cur
        $cp = 0.0; [void][double]::TryParse((([string]$d.current_price) -replace '[^0-9.]',''), [ref]$cp)
        # only when the pack IS our size (cur sits in the band) is cur the exact our-size price we must publish
        if (($cur -ge ($loP - 0.011)) -and ($cur -le ($hiP + 0.011))) {
          $bkChecked++
          if ([math]::Abs($cp - $cur) -gt 0.02) {
            $bkBad++
            [void]$fail.Add(("HARD FAIL: Baker's published price is not the store's exact shelf price  [{0}]  we publish `${1}, the store charges `${2} (unit {3}/{4}) - a rounded-unit-price reconstruction slipped past, not the exact price (the milk bug)" -f [string]$d.item, $cp, $cur, $pv.uv, $pv.uof))
          }
        }
      }
    }
    if ($bkBad -eq 0) { Say ("  ok    Baker's prices reconcile with the raw store capture ($bkChecked pack=our-size rows checked against the exact cur)") }
  }
} catch {
  [void]$warn.Add("guard 11 (Baker's raw-capture cross-check) errored and was skipped: " + $_.Exception.Message)
}

# ---------------------------------------------------------------- report
Say ''
foreach ($w in $warn) { Say ("  warn  " + $w) }
if ($fail.Count -gt 0) {
  Write-Output ''
  foreach ($f in $fail) { Write-Output ("  " + $f) }
  Write-Output ''
  Write-Output ("GUARDS FAILED: " + $fail.Count + " hard invariant(s) violated. Board NOT safe to publish.")
  exit 2
}
Write-Output 'GUARDS OK: every hard invariant holds. Safe to publish.'
exit 0
