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
    3. underivable pin : a board-price-override pin that does NOT equal the verified link it claims to be
                         derived from (hand-edited, or its link moved), has no link at all, or was derived
                         from a link name-drift flags as the wrong product. A pin BEATS the engine, so a pin
                         nobody can re-derive publishes a number nothing else can correct.
                         NOT "a pin that disagrees with the engine" - disagreeing with the engine is a pin's
                         whole JOB (generate-board-overrides pins a cell whose board price is >30% off its
                         verified link). That old test contradicted the generator AND was a no-op: it read
                         only the staple board while every pin is a recipe-board id. See the note at guard 3.
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
. (Join-Path $root 'multipack-lib.ps1')   # THE multipack math - the same one build-walmart-deals pre-filters with
$fail = New-Object System.Collections.ArrayList
$warn = New-Object System.Collections.ArrayList
function Say($s) { if (-not $Quiet) { Write-Output $s } }

# THE SAME FILE SET THE ENGINE PRICES FROM. See regular-fileset-lib.ps1 for why this is shared rather than
# re-derived here: guards used to answer "which files does the board price from?" with "the newest per store",
# which is a different answer for Walmart - the one store compare-deals unions across 14 days. 332 live
# Walmart cells were priced from files guards 5 and 10 never opened.
. (Join-Path $root 'regular-fileset-lib.ps1')
function EngineFileSet {
  # Mirrors compare-deals' own call: every canonical out\regular capture, resolved against today.
  $all = Get-ChildItem (Join-Path $root 'out\regular\*-regular-*.json') -ErrorAction SilentlyContinue
  return @(Select-RegularFileSet $all (Get-Date).Date 14)
}
$script:ENGINE_FILES = @{}
foreach ($ef in (EngineFileSet)) { $script:ENGINE_FILES[$ef.FullName] = $true }
function InEngineSet([string]$fullName) { return $script:ENGINE_FILES.ContainsKey($fullName) }

function OkUnlessBlind([int]$checked, [string]$okMsg, [string]$blindMsg) {
  <#
    THE ZERO-ROWS RULE: a check that examined NOTHING must WARN, never print ok.

    Founding bug (2026-07-24, found 2026-07-29). Guard 11 reconciles Baker's published price against the raw
    store capture. It filters rows on `$d.upc` and `source_ad -match 'bakersplus'`. When Baker's moved to the
    sanctioned Kroger API the puller started writing `product_id` and `source_ad = kroger-api`, so ZERO of
    6,960 rows matched - and because its bug counter was still 0, it printed:
        ok    Baker's prices reconcile with the raw store capture (0 pack=our-size rows checked ...)
    It said ok for five days while checking nothing. It is the ONLY independent statement of Baker's price on
    the board (guards.ps1 says so itself at the guard-10 header: guard 10 compares two of OUR OWN numbers, so
    it cannot catch a current_price that was COMPUTED wrong), and Baker's is the largest store on the board.

    "No violations found" and "no rows examined" produce the SAME zero. This helper forces them apart: pass the
    number of rows the check actually looked at, and an empty examination becomes a warn naming what went blind.
    Guard 10 already did this by hand - it warns by name for stores that record no current_price. This makes it
    the house rule rather than one guard's good manners.
  #>
  if ($checked -gt 0) { Say ('  ok    ' + $okMsg) }
  else { [void]$warn.Add($blindMsg) }
}

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
  # 2026-07-30 size-parser fixes - each want is the arithmetic truth; the pre-fix engine returned the
  # bracketed WRONG value, so these are must-fire fixtures of their founding bugs (guard-fixture-rule):
  @{ size='6-pack 12 fl oz'; unit='floz'; price=6.99; name='';              want=0.097083 }  # hyphenated pack-first [was 0.5825 - the Liquid Death 6x class]
  @{ size='.98 oz';          unit='oz';   price=0.98; name='';              want=1.0      }  # leading-dot decimal [was 0.01 - 100x, the sams grits class]
  @{ size='16 oz 6-pk';      unit='oz';   price=3.00; name='';              want=0.03125  }  # hyphenated weight-first [was 0.1875]
  @{ size='each';            unit='each'; price=6.00; name='Water 24-Pack'; want=0.25     }  # hyphenated count-in-NAME [was 6.00 - whole pack as one item]
  @{ size='12 x 12 fl oz';   unit='floz'; price=4.72; name='';              want=0.032778 }  # x-separator - worked before, pinned so it keeps working
)
$puBad = New-Object System.Collections.Generic.List[string]
foreach ($c in $puCases) {
  $g = Get-LinkPerUnit -size $c.size -unit $c.unit -price $c.price -name $c.name
  $ok = if ($null -eq $c.want) { $null -eq $g } else { ($null -ne $g) -and ([math]::Abs([double]$g - [double]$c.want) -lt 0.001) }
  if (-not $ok) { $puBad.Add(('"{0}"/{1} -> {2} (want {3})' -f $c.size, $c.unit, $g, $c.want)) }
}
if ($puBad.Count) { [void]$fail.Add("HARD FAIL: pu-lib per-unit math regressed [" + ($puBad -join '; ') + "] - the publish path prices with this engine; see test-pu-lib.ps1") }
else { Say '  ok    pu-lib per-unit engine self-check' }

# ---------------------------------------------------------------- 0b: the 2026-07-23 incident self-tests
# The Walmart alert flood had two producers: a PARTIAL pull that "newest-file-wins" turned into a coverage
# collapse (fixed by compare-deals' union), and a builder that emitted BULK MULTIPACKS (fixed by
# build-walmart-deals' reject filter). Blocking the publish was not enough - the AUTOMATED job must never
# PRODUCE the incident again. So run both scripts' -SelfTest suites here, in the gate the daily cloud job runs,
# and HARD FAIL the publish if either regresses. Each suite is pure computation (synthetic inputs, no board
# mutation, no network), safe on every run. If the invocation itself throws, degrade to a warning - a broken
# test must never block the board by crashing.
foreach ($st in @(
  @{ label='partial-pull union (compare-deals)';       file='compare-deals.ps1' },
  @{ label='multipack reject + pricing (walmart-deals)'; file='build-walmart-deals.ps1' },
  # 2026-07-27: Walmart's own unit price backed out a 10 fl oz size for a bottle its page calls 6.8 fl oz,
  # so we published fish sauce 32% under the real shelf price. The name now wins when the two disagree.
  @{ label='name-size vs Walmart unit price (walmart-batch)'; file='import-walmart-batch.ps1' }
)) {
  try {
    $stPath = Join-Path $root $st.file
    if (-not (Test-Path $stPath)) { Say ("  warn  self-test skipped, missing $($st.file)"); continue }
    & powershell -ExecutionPolicy Bypass -File $stPath -SelfTest *> $null
    if ($LASTEXITCODE -ne 0) { [void]$fail.Add("HARD FAIL: $($st.label) self-test regressed (exit $LASTEXITCODE) - run '$($st.file) -SelfTest'. This is the 2026-07-23 partial-pull / multipack guard; a regression here re-opens the flood.") }
    else { Say "  ok    $($st.label) self-test" }
  } catch { Say ("  warn  could not run $($st.label) self-test: " + $_.Exception.Message) }
}

# ADVISORY, never blocks: the Walmart union survives a partial pull only while a COMPREHENSIVE capture sits
# inside its 14-day window - and nothing else watches that (guard 9 sees file AGE, which daily partials keep
# fresh; the Wednesday watchdog sees mtimes, which a partial refresh updates). audit-walmart-fullpull.ps1 is
# the single copy of that logic; check-ad-cycles emails on it (deduped), this line just makes it visible in
# every gate run. A real expiry still fails CLOSED via the coverage-regression guard above.
try {
  $wfp = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-walmart-fullpull.ps1') 2>$null
  if ($LASTEXITCODE -eq 0) { Say ("  ok    " + [string]$wfp) }
  elseif ($LASTEXITCODE -eq 3) { [void]$warn.Add('walmart-fullpull examined ZERO captures for a union store, so it proves nothing this run: ' + [string]$wfp) }
  else { [void]$warn.Add([string]$wfp) }
} catch { Say ("  warn  could not run audit-walmart-fullpull: " + $_.Exception.Message) }

# ADVISORY, never blocks: per-CELL drop detector (Brad caught Fareway's chicken breast missing by eye on
# 2026-07-23 - the coverage guard's 5% tolerance had let 7 real cells slip). Lists every EVERYDAY cell that
# was priced ~5 days ago and is gone today, excluding the two classes that drop by design (ended sales,
# Sam's 14-day slices). With carry-forward now walking the whole window this should read zero; anything it
# names is a real, new leak.
try {
  $cdOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-cell-drops.ps1') 2>$null
  if ($LASTEXITCODE -eq 0) { Say ("  ok    " + (@($cdOut) | Select-Object -First 1)) }
  elseif ($LASTEXITCODE -eq 3) { [void]$warn.Add('cell-drops could NOT be evaluated, so it proves nothing this run: ' + ((@($cdOut) | Where-Object { $_ }) -join ' ')) }
  else { [void]$warn.Add((@($cdOut) -join ' | ')) }
} catch { Say ("  warn  could not run audit-cell-drops: " + $_.Exception.Message) }

# ADVISORY, never blocks: allowlists rot. An entry in multipack-allowlist / coverage-gap-allowlist was
# reviewed against the store ONCE and then trusted forever - but the store's packaging and naming move, so
# an entry without a `reviewed` date, or one past 120 days, deserves fresh eyes. Warn with the count; the
# entries themselves say what to re-check. (Advisory by design: an old-but-correct entry blocking the
# board would be the cries-wolf failure this file keeps re-learning.)
try {
  $stale = 0; $undated = 0
  # basis-reconcile-allowlist.json was NOT in this list, and it is the one that most needs to be. It suppresses
  # FACTOR-level disagreements between our published per-unit and the store's own unit price - which is the
  # class that decides which store the board calls cheapest. Its own readme is the sternest of the three ("a
  # factor disagreement between two independent statements of the same quantity means one of them is a basis
  # error, and basis errors are the class that lands on the cheapest-store verdict"), and it was the only
  # allowlist under no expiry pressure at all: entries could age there forever without ever being re-verified.
  foreach ($alf in @('multipack-allowlist.json', 'coverage-gap-allowlist.json', 'basis-reconcile-allowlist.json')) {
    $p = Join-Path $root $alf
    if (-not (Test-Path $p)) { [void]$warn.Add("$alf is MISSING - the allowlist-rot check scanned ZERO entries from it, and its consumers just lost their exemptions too (a moved/renamed allowlist file, not a clean bill of health)"); continue }
    $doc = Get-Content $p -Raw | ConvertFrom-Json
    # SCHEMA DRIFT MUST NOT READ AS CLEAN. This extraction knows exactly two key names; a file that used a
    # third would yield @() and contribute ZERO stale entries, so the hygiene check would report a clean bill
    # of health for a list it never opened. That is the same "no findings" / "nothing examined" collapse the
    # zero-rows rule exists for, one level up: here the thing going blind is the expiry pressure itself.
    $hasList = ($doc.PSObject.Properties['allow'] -ne $null) -or ($doc.PSObject.Properties['gaps'] -ne $null)
    if (-not $hasList) {
      [void]$warn.Add("$alf parses to NO recognised entry list (expected .allow or .gaps) - the allowlist-rot check scanned ZERO entries from it, so a stale suppression in that file is invisible")
      continue
    }
    $entries = if ($doc.PSObject.Properties['allow']) { @($doc.allow) } elseif ($doc.PSObject.Properties['gaps']) { @($doc.gaps) } else { @() }
    foreach ($e in $entries) {
      if (-not $e.PSObject.Properties['reviewed'] -or -not $e.reviewed) { $undated++; continue }
      try { if (([datetime]::Today - [datetime]$e.reviewed).TotalDays -gt 120) { $stale++ } } catch { $undated++ }
    }
  }
  if (($stale + $undated) -gt 0) { [void]$warn.Add("allowlist hygiene: $stale entr(y/ies) reviewed >120 days ago + $undated with no 'reviewed' date - re-verify against the store and stamp 'reviewed: yyyy-MM-dd' (multipack-allowlist / coverage-gap-allowlist / basis-reconcile-allowlist)") }
  else { Say '  ok    allowlist entries all carry a fresh reviewed date' }
} catch { Say ("  warn  allowlist hygiene check threw: " + $_.Exception.Message) }

# ---------------------------------------------------------------- 0d: no mojibake in the MATCHING RULES
# Seven commodity patterns carried the two HALVES of a mangled accent as separate alternatives in a character
# class - jalape[n<U+00C3><U+00B1>]os? and pur[e<U+00C3><U+00A9>]e. A character class matches ONE character, so
# that class matched neither the real n-tilde (U+00F1) nor the two-char mojibake sequence: it only ever matched
# the plain 'n'. Two-sided damage - "Jalapeno" spelled correctly could not match its own commodity, and
# butternut-squash / pie-pumpkins could not EXCLUDE a "puree", so a puree could win a whole-vegetable row.
# It mattered more after 2026-07-29, because capture-lib now repairs names on ingest, so correctly accented
# text started flowing again and the rules were pointing at the side that had gone away.
# U+00C3 / U+00C2 / U+00E2 are the lead bytes of UTF-8-read-as-Windows-1252 and are never legitimate inside a
# hand-written rule - the same signature capture-lib.ps1 defines. Advisory: this is a rules-authoring mistake,
# not unsafe data, and it should not block a board that is otherwise correct.
try {
  $cmRaw = [IO.File]::ReadAllText((Join-Path $root 'commodities.json'), [Text.Encoding]::UTF8)
  $mojiPat = '[' + [char]0x00C3 + [char]0x00C2 + [char]0x00E2 + ']'
  $mojiHits = @([regex]::Matches($cmRaw, '"[^"]*' + [regex]::Escape($mojiPat.Substring(1,1)) + '[^"]*"'))
  $mojiAll = @([regex]::Matches($cmRaw, $mojiPat))
  if ($mojiAll.Count -gt 0) {
    $sample = @([regex]::Matches($cmRaw, '"[^"]{0,60}' + $mojiPat + '[^"]{0,60}"') | Select-Object -First 3 | ForEach-Object { $_.Value })
    [void]$warn.Add("commodities.json carries $($mojiAll.Count) mojibake character(s) inside its matching rules - a class like jalape[n<C3><B1>]os? matches NEITHER the real accent nor the mangled pair, so the rule silently misses on both spellings. Use the \u00XX escape form. Samples: " + ($sample -join ' | '))
  } else { Say '  ok    matching rules carry no mojibake (accented classes use the \u00XX escape form)' }
} catch { Say ("  warn  rules-mojibake check threw: " + $_.Exception.Message) }

# ---------------------------------------------------------------- 1 + 2: delegate to the existing audits
foreach ($g in @(
    @{ f='audit-price-mode.ps1';        n='price-mode (in-store pricing)' },
    @{ f='audit-household-in-food.ps1'; n='household-in-food' },
    # blueberries-as-Bai-beverage class (2026-07-15): a FOOD commodity matched to a beverage/baby-food/pet/
    # household/bakery-carrier/dairy-carrier/candy product. Wrong-class products are usually CHEAPER than the
    # real item, so they win the cheapest slot and ship as a great-looking lie. Reads category-excludes.json -
    # the same library apply-category-excludes bakes into commodity rules and build-vet-sheet flags for review.
    @{ f='audit-food-category.ps1';     n='no food commodity matched a wrong-class product (beverage/baby/pet/household/carrier/candy)' },
    # coverage regression (2026-07-16): a store QUIETLY LOSING cells it had on the previous board. Guard 6 below
    # checks the same idea at the FILE level, and cannot see this class at all - it reads out\regular\, and Sam's
    # has no regular file (its prices come only from out\sams\ captures). So Sam's fell 251 -> 116 priced cells
    # with every guard on this page green: the publish gate enforces only a FLOOR (~15/store, which 116 clears),
    # and a store missing from a row renders as a lawful "doesn't carry" tile that no audit can distinguish from
    # a real gap. Brad caught it by eye. Intentional drops are acked in out\coverage-ack.json with an expiry.
    @{ f='audit-coverage-regression.ps1'; n='no store lost coverage vs the previous board' },
    # tile integrity (2026-07-16) - BRAD'S INVARIANT: "no tile that has a price and item name and no link, and
    # the price and item name must match the link 100%". Runs as a RATCHET, not a hard gate: 313 of 2,047 tiles
    # violate it today and nearly all need a paced per-store browser pass, so a gate that fails from day one is
    # a gate that gets switched off. It fails when a store gets WORSE than out\tile-integrity-baseline.json, so
    # the number can only go down. Flip -Strict on once it reaches zero and it becomes the hard invariant.
    @{ f='audit-tile-integrity.ps1';    n='ZERO shipped links disagree with their tile (hard), and no store regressed on coverage (ratchet)' })) {
  $p = Join-Path $root $g.f
  if (-not (Test-Path $p)) { [void]$fail.Add(("MISSING GUARD SCRIPT: " + $g.f)); continue }
  # CAPTURE the output instead of discarding it: a delegated audit that says "nothing to check" was exiting 0,
  # and this loop relabelled that as "ok  <invariant holds>". EXIT 3 now means "could not evaluate" and becomes
  # a WARN naming what went unproven. Deliberately NOT a hard fail: the no-baseline case fires on every cloud
  # run by construction (out\comparison-*.json is gitignored), so failing on it would turn a blind spot into a
  # missed board on exactly the days the local run was already missed - the cry-wolf outcome that matters most
  # here. Capturing is harmless for the other delegated audits; only exit 3 is special-cased.
  $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $p 2>$null
  if ($LASTEXITCODE -eq 3) { [void]$warn.Add($g.n + ' could NOT be evaluated, so it proves nothing this run: ' + ((@($o) | Where-Object { $_ }) -join ' ')) }
  elseif ($LASTEXITCODE -ne 0) { [void]$fail.Add(("HARD FAIL: " + $g.n + " (see " + $g.f + ")")) }
  else { Say ("  ok    " + $g.n) }
}

# ---------------------------------------------------------------- shared: the board + the links
$cmpF = Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1
$cmp  = Get-Content $cmpF.FullName -Raw | ConvertFrom-Json
$pu   = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items

# ---------------------------------------------------------------- 3: a pin must be DERIVABLE from its own link
# REWRITTEN 2026-07-16. The old invariant was "a pin must not disagree with the engine (>2%)", which was wrong
# twice over:
#
#  1. IT CONTRADICTED THE THING IT GUARDED. generate-board-overrides.ps1 EXISTS to pin a cell whose board price
#     disagrees with its verified link by >30% - "the board number is stale, pin it to the link". So the
#     generator only ever emits pins that fail the old test. Every legitimate staple pin blocked the publish;
#     this morning's blueberries/Aldi and granola-bars/Hy-Vee pins did exactly that.
#  2. IT WAS A NO-OP ANYWAY. It read only comparison-*.json (the STAPLE board), but the generator pins BOTH
#     boards ($staple + out\recipe-board.json). All 20 pins in the file right now are recipe-board ids
#     (parmesan-cheese, smoked-paprika, apple, fries...) - so `if (-not $row) { continue }` skipped every single
#     one. The guard has been reporting "ok" while checking nothing, same fail-open shape as the dead
#     name-drift check in generate-board-overrides.
#
# THE REAL INVARIANT: a pin BEATS the engine by design, so what must hold is that it is REPRODUCIBLE - it must
# equal the per-unit of the verified link it claims to come from, and that link must not be a wrong product.
# That catches what actually hurts (a hand-edited pin, a pin left behind after its link moved, a pin derived
# from a mis-resolved link) without failing the pin for doing its job. Checked across BOTH boards, with pu-lib -
# the same math build-deals-page publishes with.
$ovrF = Join-Path $root 'board-price-overrides.json'
$rogue = 0; $pinChecked = 0; $pinSkipped = 0; $pinDriftScannable = 0   # declared here: the ok line at the end
                                                                      # reads $pinDriftScannable even when the
                                                                      # overrides file does not exist
if (Test-Path $ovrF) {
  $ovr = Get-Content $ovrF -Raw | ConvertFrom-Json
  # unit per id, from BOTH boards
  $unitById = @{}
  foreach ($r in $cmp.comparison) { $unitById[[string]$r.id] = [string]$r.unit }
  $rbF = Join-Path $root 'out\recipe-board.json'
  if (Test-Path $rbF) { foreach ($r in (Get-Content $rbF -Raw | ConvertFrom-Json).comparison) { if (-not $unitById.ContainsKey([string]$r.id)) { $unitById[[string]$r.id] = [string]$r.unit } } }
  # name-drift: a pin must never be derived from a wrong-product link
  $pinDrift = @{}
  $ndF = Join-Path $root 'out\name-drift.json'
  if (Test-Path $ndF) { foreach ($d in (Get-Content $ndF -Raw | ConvertFrom-Json).flags) { $pinDrift[([string]$d.id + '|' + [string]$d.store)] = [string]$d.reason } }

  foreach ($c in $ovr.cells) {
    $id = [string]$c.id; $st = [string]$c.store
    $unit = $unitById[$id]
    if (-not $unit) { $pinSkipped++; continue }          # id on neither board -> nothing to price against
    $lnk = $pu.$id.$st
    if (-not $lnk -or -not $lnk.price) {
      $rogue++
      [void]$fail.Add(("HARD FAIL: pin has NO LINK to derive from  {0} / {1}  pin={2} - a pin beats the engine, so one that cannot be re-derived is an unsourced number nothing can correct" -f $id, $st, $c.per_unit))
      continue
    }
    if ($pinDrift.ContainsKey($id + '|' + $st)) {
      $rogue++
      [void]$fail.Add(("HARD FAIL: pin derived from a WRONG-PRODUCT link  {0} / {1}  [{2}]  link='{3}' - name-drift flags this link, so its price must not be pinned onto the board" -f $id, $st, $pinDrift[$id + '|' + $st], [string]$lnk.name))
      continue
    }
    $sp = 0.0; [void][double]::TryParse((([string]$lnk.price) -replace '[^0-9.]', ''), [ref]$sp)
    $lpu = Get-LinkPerUnit -size ([string]$lnk.size) -unit $unit -price $sp -name ([string]$lnk.name)
    if ($null -eq $lpu -or $lpu -le 0) { $pinSkipped++; continue }   # link carries no usable basis - guard 4 reports that class
    $pin = [double]$c.per_unit
    $pinChecked++
    if ([math]::Abs($lpu - $pin) / $lpu -gt 0.02) {
      $rogue++
      [void]$fail.Add(("HARD FAIL: pin does NOT match its own link  {0} / {1}  pin={2} link={3} ('{4}') - a derived pin must equal the link it came from; this one was hand-edited or its link moved" -f $id, $st, [math]::Round($pin, 4), [math]::Round($lpu, 4), [string]$lnk.name))
    }
  }
  # ZERO-ROWS RULE, applied to this guard's OTHER half. The WRONG-PRODUCT clause above only has an opinion on
  # ids that audit-name-drift actually scans, and audit-name-drift.ps1:13-14 reads out\comparison-*.json ONLY -
  # never out\recipe-board.json. Every one of today's 16 pins is a recipe-board-only id, so $pinDrift can never
  # hold a key matching ANY pin and that hard fail is structurally unfirable, while :260 prints ok with
  # $pinChecked=16. This is verbatim the fail-open this guard's own header describes: $unitById was fixed to
  # read BOTH boards, $pinDrift was left riding on a producer that still reads one.
  # Root fix is in audit-name-drift.ps1 (union recipe-board.json into its input, as done here at :227-228);
  # until then, say out loud that the identity half proved nothing.
  $ndScope = @{}; foreach ($nr in $cmp.comparison) { $ndScope[[string]$nr.id] = $true }
  $pinDriftScannable = @(@($ovr.cells) | Where-Object { $ndScope.ContainsKey([string]$_.id) }).Count
  if (@($ovr.cells).Count -gt 0 -and $pinDriftScannable -eq 0) {
    [void]$warn.Add(("guard 3's WRONG-PRODUCT clause examined ZERO of {0} pins - every pin is a recipe-board id and audit-name-drift.ps1 scans only comparison-*.json, so the hard fail at guards.ps1:244 cannot fire for any pin in the file and NO product-identity check covers the links these pins derive from. Fix: union out\recipe-board.json into audit-name-drift's input." -f @($ovr.cells).Count))
  }
}
if ($rogue -eq 0) { Say ("  ok    every override pin is derivable from its own link ($pinChecked checked for derivability; product identity checked on $pinDriftScannable of them)") }
if ($pinSkipped -gt 0) { [void]$warn.Add("$pinSkipped pin(s) could NOT be re-derived (id on neither board, or the link carries no usable unit basis) - not a pass, an unknown") }

# ---------------------------------------------------------------- 4: factor mismatch (board vs its own link)
# Per-unit math comes from pu-lib.ps1 - the SAME function build-deals-page uses to publish the number. This
# guard used to carry its own weaker copy (Qty), which returned 0 - meaning "skip this cell" - for sizes the
# published math handles fine: "per lb", a bare "lb", "24 fl oz" against an oz commodity, "dozen", and a unit
# price like "$0.07/oz" parked in the size field. That silently excluded 185 of 2,156 linked everyday cells
# (8.6%) from this check while the guard still reported "0 mismatches". A gate that grades the page with
# different arithmetic than the page was built with is not grading the page.
#
# AND IT MUST GRADE THE NUMBER THE PAGE ACTUALLY PRINTS. build-deals-page applies board-price-overrides.json to
# EVERYDAY cells, so a PINNED cell publishes the pin, not $s.per_unit. Reading the raw board here re-created the
# very flaw the paragraph above condemns - right arithmetic, wrong input - and it fired on the one cell that had
# just been FIXED: generate-board-overrides pinned all-purpose-cleaner/Hy-Vee to its verified link ($3.99/32floz
# after Hy-Vee dropped it from $5.99), the page would have published exactly the link's number, and this guard
# hard-failed it for disagreeing with that same link. A gate whose job is "board must equal its link" cannot
# fail a cell BECAUSE it was set equal to its link.
# This does not create a hole: a pinned cell is not unchecked, it is checked by invariant 3, which proves every
# pin is derivable from its own verified link (and that the link exists and name-drift does not flag it).
$pinF = Join-Path $root 'board-price-overrides.json'
$pin = @{}
if (Test-Path $pinF) {
  foreach ($c in @((Get-Content $pinF -Raw | ConvertFrom-Json).cells)) { $pin[([string]$c.id + '|' + [string]$c.store)] = [double]$c.per_unit }
}
$unpriceable = 0
$factorBugs = 0; $drift = 0; $pinned = 0
# ZERO-ROWS RULE for the factor guard. Both lookups below - `$link = $pu.($row.id)` and `$e = $link.($s.store)`
# - `continue` in SILENCE, so every way this guard can go blind is invisible in its own output. It was the only
# numbered guard reporting no coverage figure of any kind, after its own header essay twice condemned exactly
# that. Measured 2026-07-29: 493 board rows, 2,653 everyday cells on linked rows, 2,341 actually COMPARED -
# 312 cells skipped for a missing store link and 3 rows with no product-urls entry at all, none of it reported.
# product-urls.json is a rebuilt artifact: rename its `items` wrapper, or let a store key drift ("Bakers" vs
# "Baker's"), and this guard silently compares nothing while still printing ok. There is no Set-StrictMode in
# this tree, so `$null.($row.id)` returns $null rather than throwing - the failure is quiet by construction.
$fcChecked = 0; $fcByStore = @{}; $fcBoardStores = @{}
# Presence pass, deliberately SEPARATE from the main loop: which stores have at least one EVERYDAY cell on the
# board at all? It cannot be counted inside the loop below, because the `-not $link` continue at row level
# skips every store on that row before they are ever seen.
foreach ($row in $cmp.comparison) {
  foreach ($s in $row.stores) {
    if (([string]$s.type) -eq 'everyday') { $fcBoardStores[[string]$s.store] = 1 + [int]$fcBoardStores[[string]$s.store] }
  }
}
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
    # the EFFECTIVE per-unit: what build-deals-page will actually publish for this cell
    $k = [string]$row.id + '|' + [string]$s.store
    $bpu = if ($pin.ContainsKey($k)) { $pinned++; $pin[$k] } else { [double]$s.per_unit }
    if ($bpu -le 0 -or $lpu -le 0) { continue }
    # Counted HERE, past every silent `continue`, so it is the number of cells actually compared - not the
    # number looked at. That distinction is the whole point of the rule.
    $fcChecked++; $fcByStore[[string]$s.store] = 1 + [int]$fcByStore[[string]$s.store]
    $ratio = $lpu / $bpu
    if ($ratio -ge 1.5 -or $ratio -le 0.67) {
      $factorBugs++
      [void]$fail.Add(("HARD FAIL: {0}x factor  {1} / {2}  board={3} link={4}  [{5}]" -f [math]::Round($ratio,2), $row.id, $s.store, [math]::Round($bpu,4), [math]::Round($lpu,4), $e.name))
    } elseif ([math]::Abs($ratio - 1) -gt 0.02) { $drift++ }
  }
}
# The helper sits INSIDE the $factorBugs -eq 0 conditional, exactly as guard 11 does: dropping that wrapper
# would print the ok line on runs that hard-fail.
if ($factorBugs -eq 0) {
  OkUnlessBlind $fcChecked `
    ('no board cell differs from its linked product by a factor (' + $fcChecked + ' cells compared)' + $(if ($pinned) { " ($pinned pinned cell(s) graded at the pin - the number the page prints - and cross-checked by invariant 3)" } else { '' })) `
    'guard 4 compared ZERO board cells against their links and therefore proves NOTHING - check that product-urls.json still parses to .items and that its store keys still match the board''s store names'
}
# PER-STORE blindness, the guard-10 pattern: the whole guard can be healthy while one store's slice is gone.
# Losing a store's product-urls entries entirely would leave $fcChecked large and that store unchecked.
# Guarded on $fcChecked -gt 0 so a fully-blind run raises the message above rather than both.
$fcBlind = @($fcBoardStores.Keys | Where-Object { [int]$fcByStore[$_] -eq 0 } | Sort-Object)
if ($fcChecked -gt 0 -and $fcBlind.Count) {
  [void]$warn.Add("guard 4 compared ZERO cells for these stores, so their board prices are unchecked against their own links: " + ($fcBlind -join ', ') + " - their product-urls slice is missing, or its store key drifted from the board's store name")
}
if ($drift -gt 0) { [void]$warn.Add("$drift cell(s) drift from their link by <50% (ordinary price movement; the daily consistency repair handles it)") }
# SAY WHAT WAS NOT CHECKED. The previous version skipped unparseable cells in silence, so its clean result
# covered 91% of the board while reading as though it covered all of it. Coverage a gate does not report is
# coverage nobody can audit.
if ($unpriceable -gt 0) { [void]$warn.Add("$unpriceable linked cell(s) carry no usable unit basis (empty/odd size) and could NOT be factor-checked - not a pass, an unknown") }

# ---------------------------------------------------------------- 5: multipack size
# A GATE THAT CRIES WOLF IS A GATE THAT GETS IGNORED - and this one was blocking the nightly publish outright.
# The check hard-failed EVERY name containing "(N pack)" whose size was a plain weight, and then asked a human to
# hand-write an allowlist entry per row "after confirming the size really is the pack total". That is arithmetic,
# and arithmetic is this script's job: on 2026-07-16 all 19 of its hard fails were FALSE POSITIVES whose size was
# already the correct total ("(12 pack) Great Value Great Northern Beans, 15.5 oz" -> size 186.4 = 12 x 15.5;
# "(4 pack) Armour Star Beef Stew ... 20 oz Can" -> size 80 = 4 x 20, and $10.72/80oz = the $0.134/oz the board
# publishes, correct). Every Walmart pull that adds a verbose "(N pack)" title turned the gate red until someone
# typed an entry, so the real bug was the DESIGN: it demanded a human for something it could verify itself.
# Now it does the multiplication. The allowlist stays for the residue it genuinely CANNOT verify: names that
# declare a pack count but state no per-unit weight ("Summit Cola 12 Pack"), and names where the stated weight is
# the package TOTAL rather than one unit ("Knorr Bouillon Cubes, 3.1 oz, 8 Pack Box" - 8 cubes inside a 3.1 oz
# box). Those still need a human to look at the store page, which is the only thing a human is actually needed for.
# 2026-07-23: the arithmetic above now lives in multipack-lib.ps1 (dot-sourced at the top), shared with
# build-walmart-deals.ps1's pre-filter so builder and gate can never drift apart - a row the builder keeps
# is a row this guard accepts, by construction. The essay above stays here because THIS is where the
# design was learned; the lib is deliberately just the math.
$allow = Get-MpAllowKeys $root
$mp = 0; $mpTotals = 0; $mpSeen = 0
foreach ($f in (RegFiles)) {
  $prefix = ($f.BaseName -replace '-regular-.*$','')
  # ITERATE THE FILE SET THE ENGINE PRICED FROM, not just the newest file per store. compare-deals unions
  # Walmart across 14 days (it has no ad cycle, so a partial capture must not replace a full one), and this
  # guard used to open only the newest file - leaving 332 live Walmart cells, about a third of the store,
  # structurally unreachable by guard 5 (multipack size). Shared definition: regular-fileset-lib.ps1.
  if (-not (InEngineSet $f.FullName)) { continue }
  $doc = Get-Content $f.FullName -Raw | ConvertFrom-Json
  foreach ($d in $doc.deals) {
    $name = [string]$d.item; $size = [string]$d.size
    $verdict = Test-MpClassify ([string]$doc.store) $name $size $allow
    if ($verdict -eq 'not-multipack') { continue }
    # the size already IS the pack total -> the row is correct, not a bug. Do the multiplication rather than
    # demanding a human confirm it (see the note above).
    if ($verdict -eq 'pack-total')  { $mpTotals++; $mpSeen++; continue }
    if ($verdict -eq 'allowlisted') { $mpSeen++; continue }
    # NOTHING TO MULTIPLY -> STILL A HARD FAIL. This gate fails CLOSED, on purpose.
    # I first made this case an "unknown" (count it, warn, move on), because 109 of Walmart's 711 board item
    # names are TRUNCATED AT EXACTLY 60 CHARS and the per-unit weight lives at the END of a grocery name, so it
    # is simply gone - "(4 pack) Armour Star ... Beef Stew, 13g Protei" lost its "20 oz Can". test-guards.ps1
    # failed on the next run: the ORIGINAL Sam's bug this guard was built for is "ReaLemon 100% Lemon Juice
    # (2 pk)" with size "48 fl oz" (one bottle; truth 2 x 48) - a name with a pack count and NO weight. My
    # escape hatch swallowed it. A price guard that goes quiet when it cannot tell is worse than one that cries
    # wolf: the wolf here publishes a 2x price. So when the arithmetic cannot decide, FAIL, and let a human
    # clear it in multipack-allowlist.json with the reasoning written down.
    # WHERE THE TRUNCATION COMES FROM - and where it does NOT: I first blamed
    # hyvee\browser-link-resolve.js's .slice(0, 60) and wrote that into this comment and 7 allowlist entries.
    # THE DATA SAYS OTHERWISE: that slice writes product-urls LINK names, and Walmart's link names are not
    # truncated (458 names, only 6 at exactly 60, max 85). The truncation is in out\regular\walmart-regular
    # (109 of 711 at exactly 60, vs 32 at 59 and 4 at 61 - a textbook cap), and no script in this repo caps at
    # 60. It was baked in by a historical capture whose code is gone. So there is no live bleed to stop, the
    # full names are NOT recoverable locally (0 of 109 can be prefix-matched against any name we hold), and the
    # only real fix is a fresh Walmart capture. The slice was fixed anyway - it was the same mistake, smaller.
    $mp++; $mpSeen++
    [void]$fail.Add(("HARD FAIL: multipack size  [{0}] '{1}' size=[{2}] records ONE unit (name says a pack count and its stated weight does not reconcile with the size)" -f $doc.store, $name, $size))
  }
}
# ZERO-ROWS RULE. $mpSeen counts rows this guard formed an actual VERDICT about, not rows it looped over
# (15,706 today - that can only be 0 if out\regular is empty, so it would never fire). The distinction matters
# because the loop above reads RegFiles() ONLY, and Sam's live feed is out\sams\sams-deals-<date>.json - the
# only Sam's rows this guard sees come from the 60-row sams-regular-2026-07-14 orphan that guards.ps1 itself
# documents as unrefreshed. So this guard's OWN founding bug - Sam's "ReaLemon 100% Lemon Juice (2 pk)" with
# size "48 fl oz", quoted 20 lines up - now arrives through a file it never opens.
# Do NOT simply widen the loop to out\sams: multipack-lib.ps1 cannot parse "8 fl. oz., 24 pk." and that change
# emits 242 hard fails from CORRECT rows. Teaching the unit regex is a separate, advisory-first change.
# $mpSeen is 121 today (all Walmart) and was 0 for every newest-Walmart file from 2026-07-05 to 07-14, so a
# terser Walmart capture silently turns this invariant into a no-op - which is exactly what this warn catches.
if ($mp -eq 0) {
  OkUnlessBlind $mpSeen `
    ("no multipack row prices a pack as a single unit ($mpTotals pack-total size(s) verified by arithmetic out of $mpSeen pack-shaped row(s))") `
    'guard 5 formed ZERO multipack verdicts this run - no row in out\regular declared a pack count its size could be tested against, so this invariant was asserted without examining anything. Sam''s live feed (out\sams) and the Baker''s/Fareway deal files are outside this guard''s file loop entirely.'
}


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
$stale = 0; $aged = 0
foreach ($f in (RegFiles)) {
  $prefix = ($f.BaseName -replace '-regular-.*$','')
  $newest = RegFiles ($prefix + '-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1
  if ($f.FullName -ne $newest.FullName) { continue }
  $doc = Get-Content $f.FullName -Raw | ConvertFrom-Json
  $store = [string]$doc.store
  $rows = @($doc.deals)
  if (-not $rows.Count) {
    # ZERO-ROWS RULE. A store whose newest file parses to no deals used to be skipped in silence - it produced
    # neither its freshness note nor its >14-day HARD FAIL, so nothing was watching its clock at all. That is
    # exactly the throttled-partial class (a 0-row PARTIAL file), and guard 6 also misses it whenever the store
    # has fewer than 2 files. Named by \ (from the FILENAME) and not \, which is read from the
    # very document whose deals array is empty and can therefore be '' - naming nobody is the one failure this
    # rule exists to prevent.
    [void]$warn.Add(("{0}: newest price file '{1}' parsed to ZERO rows - neither the freshness note nor the >14-day staleness test could run for this store, and nothing else is watching its clock" -f $prefix, $f.Name))
    continue
  }

  # how many rows carry a date, and how old is the freshest?
  $dated = @($rows | Where-Object { $_.as_of })
  $unver = @($rows | Where-Object { $_.not_reverified }).Count
  $fileDate = $today
  if ($f.BaseName -match '(\d{4}-\d{2}-\d{2})$') { try { $fileDate = [datetime]$Matches[1] } catch {} }

  # MEASURE THE FILE THE ENGINE ACTUALLY PRICED FROM (2026-07-29). Sam's is the one store that does not write
  # out\regular\<store>-regular-<date>.json - its prices reach the board through out\sams\sams-deals-*.json via
  # -SamsFile, and out\regular\sams-regular-*.json only ever held a one-off hand-promotion from 2026-07-14
  # ("promoted from verified recipe pricing", 60 rows) that NOTHING refreshes. So this check was aging out an
  # orphan and hard-failing the publish on a day the Sam's pull had just succeeded with 316 terms and 7,110
  # rows. A gate that fails no matter how well the job runs is a gate people learn to ignore.
  # Same principle derive-links-from-prices already adopted: index the SAME files the engine priced from.
  $altGlob = switch ($store) {
    "Sam's Club" { 'out\sams\sams-deals-*.json' }
    "Baker's"    { 'out\bakers\bakers-deals-*.json' }
    'Fareway'    { 'out\fareway\fareway-deals-*.json' }
    default      { '' }
  }
  if ($altGlob) {
    $alt = Get-ChildItem (Join-Path $root $altGlob) -ErrorAction SilentlyContinue |
           Where-Object { $_.BaseName -match '\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
    # [regex]::Match, not -match: $Matches is global and the next -match anywhere in this block would clobber
    # the captured date out from under us. That trap is documented in this estate and has cost a run before.
    $altDateStr = ''
    if ($alt) { $am = [regex]::Match($alt.BaseName, '(\d{4}-\d{2}-\d{2})$'); if ($am.Success) { $altDateStr = $am.Groups[1].Value } }
    if ($altDateStr) {
      try {
        $altDate = [datetime]$altDateStr
        if ($altDate -gt $fileDate) {
          $fileDate = $altDate
          # TAKE THE ROWS FROM THAT FILE TOO - not just the date. The 2026-07-29 fix redirected only the AGE
          # and left $rows/$dated/$unver reading out\regular, so Sam's freshness was still being measured on
          # sams-regular-2026-07-14.json: a 60-row one-off hand-promotion that NOTHING refreshes, while the
          # live feed it is standing in for holds 2,537 rows. The printed "60 rows | 0% re-verified" was
          # therefore unfixable by definition - no successful pull could ever move it, because no pull writes
          # that file. A number that cannot change is not a measurement, and guard 9's own warn text calls
          # these percentages "the only thing standing between them and the basePrice bug".
          try {
            $altDoc = Get-Content $alt.FullName -Raw | ConvertFrom-Json
            $altRows = @($altDoc.deals)
            if ($altRows.Count) {
              $rows  = $altRows
              $dated = @($rows | Where-Object { $_.as_of })
              $unver = @($rows | Where-Object { $_.not_reverified }).Count
            }
          } catch { [void]$warn.Add("guard 9 could not read $($alt.Name) for $store - freshness is still being measured on the stale out\regular file: " + $_.Exception.Message) }
        }
      } catch {}
    }
  }

  $age = [int]($today - $fileDate).TotalDays
  $verifiedToday = 0
  foreach ($r in $dated) { if (([string]$r.as_of) -eq (Get-Date -Format 'yyyy-MM-dd')) { $verifiedToday++ } }

  $pct = 0
  if ($rows.Count -gt 0) { $pct = [math]::Round(100.0 * $verifiedToday / $rows.Count) }
  # THE ZERO-ROWS RULE, APPLIED TO A PERCENTAGE. "0% re-verified" and "these rows carry no date to check"
  # produce the same 0 and read identically - but one is a store that went unverified today and the other is a
  # feed where verification CANNOT be expressed at all. Measured 2026-07-30: 0 of 2,537 Sam's rows, 0 of 29
  # Baker's and 0 of 11 Fareway rows carry `as_of`, so their percentage is structurally zero forever and no
  # successful pull can ever move it. Reporting that as "0% re-verified" invites someone to go fix a pull that
  # is not broken; the actual fix is for those builders to stamp as_of, and this says so.
  if ($dated.Count -eq 0) {
    $note = ("{0,-13} {1,4} rows | NO as_of ON ANY ROW - freshness cannot be measured, only file age | file {2}d old" -f $store, $rows.Count, $age)
  } else {
    $note = ("{0,-13} {1,4} rows | {2,3}% re-verified against the store TODAY ({3} of {4} dated) | file {5}d old" -f $store, $rows.Count, $pct, $verifiedToday, $dated.Count, $age)
  }
  if ($unver -gt 0) { $note += (" | {0} row(s) flagged unverified" -f $unver) }
  # Only stores that HAVE a regular/discounted split can suffer the Hy-Vee/Baker's bug. Aldi was checked and
  # cannot: it is everyday-low-price and its listings carry a single "Current price" with no was/now pair
  # anywhere. Flagging it for a bug it structurally cannot have would be crying wolf, and a warning nobody
  # believes is a warning nobody reads.
  if (($verifiedToday -eq 0) -and ($store -ne 'Aldi')) {
    $note += '  <-- NOT price-verified today: this store CAN discount, so it may be publishing regular prices (the Hy-Vee/Baker''s bug)'
  }
  [void]$warn.Add($note)
  $aged++   # a store that completed its freshness note - this is the count the ok line below gates on

  # a store nobody has looked at in over two weeks is not "safe", it is unknown
  if ($age -gt 14) {
    $stale++
    [void]$fail.Add(("HARD FAIL: {0} price data is {1} days old - a stale price is a wrong price" -f $store, $age))
  }
}
# The $stale -eq 0 wrapper STAYS: OkUnlessBlind prints ok whenever the count is non-zero, so dropping it would
# announce "no store's price data is older than 14 days" on the very run where a 15-day-old store just filed
# the HARD FAIL above. Same shape guard 11 uses.
if ($stale -eq 0) {
  OkUnlessBlind $aged "no store's price data is older than 14 days ($aged store(s) aged)" `
    'guard 9 aged ZERO stores - out\regular yielded no readable per-store data, so NOTHING checked any store''s clock. Guard 10''s own header names guard 9 as the only staleness watch on Baker''s, Fareway, Sam''s and Walmart.'
}

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
  # ITERATE THE FILE SET THE ENGINE PRICED FROM, not just the newest file per store. compare-deals unions
  # Walmart across 14 days (it has no ad cycle, so a partial capture must not replace a full one), and this
  # guard used to open only the newest file - leaving 332 live Walmart cells, about a third of the store,
  # structurally unreachable by guard 10 (never publish the REGULAR price). Shared definition: regular-fileset-lib.ps1.
  if (-not (InEngineSet $f.FullName)) { continue }
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
    # A MULTIBUY MAKES THESE TWO LEGITIMATELY DIFFER, BY EXACTLY THE MULTIPLE. current_price is the store's
    # headline ("3 for $4" -> 4); ad_price is the per-item price we publish (1.3333). Compared raw, this guard
    # called 18 rows of correct data the basePrice bug (Hass Avocados, 2L Pepsi, Chips Ahoy - every ratio a
    # clean 2x/3x/4x, which is the tell). Multiply our price back up by the divisor the puller recorded and the
    # two must land on the same number.
    # This does NOT weaken the check: it still proves ad_price came from storeProducts.price rather than
    # basePrice, because basePrice * mult does not equal sp.price. A row that omits price_multiple is compared
    # exactly as before, so no store loses coverage.
    $mult = 1.0
    if ($d.price_multiple) { [void][double]::TryParse(([string]$d.price_multiple), [ref]$mult) }
    if ($mult -le 0) { $mult = 1.0 }
    $apTotal = $ap * $mult
    if ([math]::Abs($apTotal - $cp) -gt ([math]::Max(0.005, $cp * 0.001))) {
      $mismatch++
      $mtxt = if ($mult -gt 1) { (" (x" + $mult + " multibuy -> `$" + [math]::Round($apTotal,2) + ")") } else { '' }
      [void]$fail.Add(("HARD FAIL: publishing a price the store is NOT charging  [{0}] {1}  we publish `${2}{3}, the store charges `${4} - the puller took the wrong price field (this is the basePrice bug)" -f $store, [string]$d.item, $ap, $mtxt, $cp))
    }
  }
  if (-not $any) { $noContract[$store] = $true }
}
if ($mismatch -eq 0) { Say ("  ok    every price we publish is the price the store charges ($checked rows verified against their own current_price)") }
if ($noContract.Count) {
  [void]$warn.Add(("these stores do NOT record the store's current price on their rows, so guard 10 CANNOT check them: " + (($noContract.Keys | Sort-Object) -join ', ') + " - until their pullers record current_price, guard 9's freshness numbers are the only thing standing between them and the basePrice bug"))
}

# ---------------------------------------------------------------- 11: Baker's price PROVENANCE
# RETIRED AND REPLACED 2026-07-30. What used to live here was a reconcile against out\bakers-prices-raw.csv,
# built for the 2026-07-14 milk bug: bakersplus printed its unit price coarsely ("$0.02/fl oz"), the importer
# rebuilt per-gallon as 0.02 x 128 = $2.56 and published it against the $3.19 the store charges. That bug was
# a property of SCRAPING A ROUNDED UNIT PRICE OFF A PAGE. Baker's moved to the sanctioned Kroger API on
# 2026-07-24, where current_price is it.price.promo/regular taken verbatim - nothing is reconstructed, so that
# reconstruction cannot happen. The check had also been silently dead since that switch (it filtered on .upc
# and source_ad 'bakersplus'; the API writes product_id and 'kroger-api'), examining ZERO of 6,960 rows while
# printing ok, until the zero-rows rule caught it earlier today.
#
# ITS JOB IS NOW DONE BETTER ELSEWHERE. audit-basis-reconcile.ps1 gives Baker's an independent price proof
# from Kroger's own itemInformation.netWeight - a field independent of every size string WE parse - and it
# checks the SHIPPED CELL rather than the captured row, so it also catches corruption introduced downstream by
# carry-forward, an override or a board merge. Guard 11 could never see any of that.
# Its coverage is deliberately narrow (compound "4 pk 16 oz" shapes only): trusting netWeight on plain labels
# was MEASURED on 6,857 rows and was wrong in every adjudicable case - apples labelled "5 Pound" report a 3 lb
# netWeight, a 12 oz tuna can reports its 5 oz drained weight. Narrow and right beats broad and noisy.
#
# WHAT REMAINS WORTH ASSERTING is the premise all of that rests on: that Baker's prices still arrive verbatim
# from the sanctioned API. If the capture ever reverts to scraping a page, the milk-bug class comes back and a
# real reconcile is needed again - so this warns loudly rather than silently inheriting an assumption.
try {
  $bkNewest = RegFiles 'bakers-regular-*.json' | Sort-Object Name -Desc | Select-Object -First 1
  if ($bkNewest) {
    $bkDoc = Get-Content $bkNewest.FullName -Raw | ConvertFrom-Json
    $bkRows = @($bkDoc.deals)
    $bkApi = @($bkRows | Where-Object { ([string]$_.source_ad) -eq 'kroger-api' }).Count
    $bkCur = @($bkRows | Where-Object { $null -ne $_.current_price }).Count
    if ($bkRows.Count -gt 0 -and $bkApi -lt $bkRows.Count) {
      [void]$warn.Add(("Baker's price provenance CHANGED: only {0} of {1} rows carry source_ad='kroger-api'. Prices no longer arrive verbatim from the sanctioned API, so the reconstructed-unit-price class (the 2026-07-14 milk bug) is possible again and audit-basis-reconcile's netWeight proof may not cover the new source. Re-establish a reconcile before trusting this store." -f $bkApi, $bkRows.Count))
    } else {
      OkUnlessBlind $bkRows.Count `
        ("Baker's prices arrive verbatim from the sanctioned Kroger API ($bkApi rows, $bkCur carrying current_price); independent proof is audit-basis-reconcile's netWeight check") `
        "guard 11 examined ZERO Baker's rows - the newest bakers-regular file parsed to nothing, so the provenance of the board's largest store is unverified"
    }
  } else {
    [void]$warn.Add("guard 11: no bakers-regular-<date>.json at all - Baker's price provenance is unverified and audit-basis-reconcile has nothing to index")
  }
} catch {
  [void]$warn.Add("guard 11 (Baker's price provenance) errored and was skipped: " + $_.Exception.Message)
}
# ---------------------------------------------------------------- 12: the board must be built from TODAY'S ads
# I published a TWO-DAY-OLD BOARD to the live site on 2026-07-17 and only caught it afterwards.
# WHY IT IS SO EASY: out\comparison-*.json is gitignored ON PURPOSE (it is regenerable, and not tracking it is
# what keeps the local browser agents from fighting the cloud over derived files). So the cloud's fresh board
# NEVER arrives on this machine - `git pull` brings down today's ADS but leaves comparison-* at whatever this
# machine last built. Every downstream step then happily uses the newest board it can SEE, which is not the
# newest board that EXISTS. Nothing was broken; everything was consistent; the answer was two days stale.
# So: if an ads file is newer than the board, the board was not built from it. Refuse.
try {
  $newestAds = Get-ChildItem (Join-Path $root 'out\ads-*.json') -EA SilentlyContinue |
    Where-Object { $_.BaseName -match '^ads-(\d{4}-\d{2}-\d{2})$' } | Sort-Object Name -Desc | Select-Object -First 1
  $newestCmp = Get-ChildItem (Join-Path $root 'out\comparison-*.json') -EA SilentlyContinue |
    Where-Object { $_.BaseName -match '^comparison-(\d{4}-\d{2}-\d{2})$' } | Sort-Object Name -Desc | Select-Object -First 1
  if ($newestAds -and $newestCmp) {
    $adsDate = ($newestAds.BaseName -replace '^ads-', '')
    $cmpDate = ($newestCmp.BaseName -replace '^comparison-', '')
    if ($adsDate -gt $cmpDate) {
      [void]$fail.Add("HARD FAIL: the board is STALE - ads-$adsDate exists but the newest board is comparison-$cmpDate. Run compare-deals.ps1 before publishing; comparison-*.json is gitignored, so a `git pull` gives you today's ads and LEAVES YESTERDAY'S BOARD.")
    }
    else { Say ("  ok    the board is built from the newest ads file (ads-$adsDate -> comparison-$cmpDate)") }
  }
  else { [void]$fail.Add('HARD FAIL: guard 12 could not find an ads-<date>.json or comparison-<date>.json to compare. It cannot prove the board is fresh, and unknown is not a pass.') }
}
catch {
  # FAIL, DO NOT WARN. I wrote this guard against a variable ($OutDir) that does not exist in this file; it
  # threw on every run, the catch quietly filed it as a warn, and guards still said "OK: every hard invariant
  # holds". A guard that cannot run is not a passing guard - it is no guard, and it reported itself healthy.
  # That is the exact sin this file exists to catch, committed inside the file itself.
  [void]$fail.Add('HARD FAIL: guard 12 (board freshness vs ads) ERRORED and therefore proved nothing: ' + $_.Exception.Message)
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
