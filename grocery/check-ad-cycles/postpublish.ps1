# ---- THE BOARD vs ITS OWN LINKS (everyday cells only) ----
# WAS AN ORPHAN. audit-everyday-mismatch.ps1 is the only check that asks "does the number we published agree
# with the product page we linked to?", it works, and until now NOTHING invoked it - not guards.ps1, not this
# file. It could find real defects every day and no one would ever read them. (Found 5 on 2026-07-31.)
# STRICTLY ADVISORY, and that is measured, not assumed: on a 43-finding day only 3 were wrong NUMBERS, and in
# the other 40 the BOARD was right and the LINK was stale. Gating a publish on this would hold correct boards
# hostage to stale links. Exit 1 means "found disagreements", not "failed"; only exit 3 (could-not-evaluate)
# and an unexpected code are worth a REVIEW line of their own.
# Placed here, at the end of the cycle: it reads the newest comparison-*.json and product-urls.json, so it
# must run after compare-deals AND after the link repairs above, and before the coverage ratchet below so its
# row is on the ledger when the ratchet reads it. No 2>&1 (EAP=Stop turns a child's stderr into a throw).
try {
  $emPath = Join-Path $root 'audit-everyday-mismatch.ps1'
  if (Test-Path $emPath) {
    $emOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $emPath -OutDir $OutDir
    $emRc  = $LASTEXITCODE
    foreach ($l in @($emOut)) { Log ('everyday-mismatch: ' + $l) }
    if ($emRc -eq 1) {
      # [regex]::Match, NOT -match + $Matches. $Matches is GLOBAL in PowerShell, so reading it downstream of a
      # -match inside a pipeline both depends on and clobbers state this file uses elsewhere - a trap this
      # repo has already been bitten by. A local Match object carries its own groups and touches nothing.
      $emM = [regex]::Match((@($emOut) -join "`n"), 'EVERYDAY MISMATCHES[^:]*:\s*(\d+)')
      $emN = if ($emM.Success) { $emM.Groups[1].Value } else { 'some' }
      $summary += ('REVIEW    everyday-mismatch: ' + $emN + ' board cell(s) disagree with their own linked product - usually a stale LINK, not a wrong price; see out\everyday-mismatches.json')
    }
    elseif ($emRc -eq 3) {
      $summary += 'REVIEW    everyday-mismatch could not evaluate - the board/link agreement check proved nothing this cycle'
    }
    elseif ($emRc -ne 0) {
      Log ("everyday-mismatch: DID NOT RUN - exit $emRc with " + @($emOut).Count + ' output line(s)')
      $summary += 'REVIEW    everyday-mismatch did not complete - board/link agreement went unchecked this cycle'
    }
  }
} catch { Log ('everyday-mismatch threw: ' + $_.Exception.Message) }

# ---- THE EXCLUDE ACCESSOR AGREES WITH THE MATCHER, OVER TODAY'S CAPTURE NAMES (2026-09-23) ----
# The live half of test-commodity-rules-lib.ps1's corpus case. At push time that case now reads a FROZEN name list
# (grocery\regression-inputs\commodity-rules-corpus-2026-09-23.json), because reading the newest capture made it
# uncacheable and cost 322 s of every push; this asks the same question over the names the stores sent today. It
# reads captures and the rules only, so its place in the chain is free; it sits here beside the other agreement
# audits. Exit 1 = a name one copy of the rule refuses and the other admits; 3 = could not look. No 2>&1.
try {
  $craPath = Join-Path $root 'audit-commodity-rules-agree.ps1'
  if (Test-Path $craPath) {
    $craOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $craPath
    $craRc  = $LASTEXITCODE
    foreach ($l in @($craOut)) { Log ('commodity-rules-agree: ' + $l) }
    if ($craRc -eq 1) {
      $summary += 'REVIEW    commodity-rules-agree: the exclude accessor and match-lib disagree on a live name - a script reading the accessor decides differently from the engine'
      if (-not $NoAlert) { Send-Alert -Subject 'Grocery commodity rules: the accessor disagrees with the matcher' -Body ("grocery\audit-commodity-rules-agree.ps1 compared commodity-rules-lib.ps1's effective exclude set with match-lib's matcher over the newest capture's names and found a disagreement: every script that reads the accessor (the non-applying audits) now decides a name differently from the engine. Fix the copy that drifted in commodity-rules-lib.ps1 or match-lib.ps1, then re-run the audit; freeze a disagreeing name into the fixture if it is a new shape.`n`n" + (@($craOut) -join "`n")) | Out-Null }
    }
    elseif ($craRc -ne 0) {
      $summary += ('REVIEW    commodity-rules-agree could not evaluate (exit ' + $craRc + ') - the accessor/matcher agreement went unchecked over live names')
      if (-not $NoAlert) { Send-Alert -Subject 'Grocery commodity rules: the agreement check could not evaluate' -Body ("grocery\audit-commodity-rules-agree.ps1 exited " + $craRc + ": no readable regular capture, fewer than 10 names, or match-lib.ps1 / commodities.json missing. Nothing was proven about the live names; the push-time frozen case still ran.`n`n" + (@($craOut) -join "`n")) | Out-Null }
    }
  }
} catch { Log ('commodity-rules-agree threw: ' + $_.Exception.Message) }

# ---- THE SAME COMMODITY MUST NOT BE PUBLISHED ON BOTH BOARDS ----
# recipe-overlay (line ~699) drops any recipe row whose commodity also lives on the weekly board, and since
# 2026-08-08 it resolves the two id spellings through recipe-floor-id-map.json. This is the independent
# second opinion on that, and it exists because the de-dup was silently half-blind for 9 days: it compared
# raw ids, the namespaces spell 33 shared commodities differently, and the site served two prices for the
# same product (beef chuck roast at Family Fare, $8.49 against $10.99). Re-deriving the collision set from
# the data every run means the next mapping added without teaching the de-dup about it fires HERE instead
# of reaching a shopper.
# ADVISORY IN THE CHAIN, on purpose and against my instinct. The condition is a genuine correctness defect
# and the script exits 2 for it, but this gate is one day old and runs inside the unattended 6:30am job; a
# brand-new check that can halt that run is the failure this estate has already had once. It reports loudly
# now, and can be promoted to a hold once it has a clean history behind it.
# Placed after everyday-mismatch so the comparison is final, and before the coverage ratchet so its row is
# on the ledger when the ratchet reads it. No 2>&1 (EAP=Stop turns a child's first stderr line into a throw).
try {
  $brPath = Join-Path $root 'audit-board-reconciliation.ps1'
  if (Test-Path $brPath) {
    $brOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $brPath -OutDir $OutDir
    $brRc  = $LASTEXITCODE
    foreach ($l in @($brOut)) { Log ('board-reconciliation: ' + $l) }
    if ($brRc -eq 2) {
      # [regex]::Match, NOT -match + $Matches: $Matches is GLOBAL and this file reads it elsewhere.
      $brM = [regex]::Match((@($brOut) -join "`n"), 'PUBLISHED ON BOTH BOARDS:\s*(\d+)')
      $brN = if ($brM.Success) { $brM.Groups[1].Value } else { 'some' }
      $summary += ('REVIEW    board-reconciliation: ' + $brN + ' commodity(ies) are published on BOTH boards - the site is showing two prices for the same product; see out\board-reconciliation.json')
    }
    elseif ($brRc -eq 1) {
      $summary += 'REVIEW    board-reconciliation: the boards are de-duplicated but a price or basis contradiction remains; see out\board-reconciliation.json'
    }
    elseif ($brRc -eq 3) {
      $summary += 'REVIEW    board-reconciliation could not evaluate - nothing proved this cycle about the same fact being published twice'
    }
    elseif ($brRc -ne 0) {
      Log ("board-reconciliation: DID NOT RUN - exit $brRc with " + @($brOut).Count + ' output line(s)')
      $summary += 'REVIEW    board-reconciliation did not complete - duplicate-commodity publishing went unchecked this cycle'
    }
  }
} catch { Log ('board-reconciliation threw: ' + $_.Exception.Message) }

# ---- RESCUE WORKLIST FOR THE WALLED STORES (Walmart, Sam's, Aldi, Fareway) ----
# The four walled stores are captured by hand through a browser, and compare-deals hands each commodity to
# the FRESHEST capture in a 14-day window OUTRIGHT. Two things fall out of that and nothing used to turn
# either into a to-do list: cells silently counting down to the day their only source leaves the window
# (21 Walmart produce cells on 2026-07-31, all of them renamed products newer captures missed by name),
# and a re-capture that is BIGGER overall but narrower on some terms (Aldi's 1,664-row 07-29 pass still
# cost 7 staple cells). audit-walmart-fullpull COUNTS the first; audit-cell-drops reports the second AFTER
# the loss. This turns both, plus the already-past-the-window pocket at Sam's, into per-store search lists.
# ADVISORY AND NOTHING ELSE: exit 1 means "capture work exists", never "hold the board". The output is a
# to-do list for the next browser session.
# Placed after the everyday-mismatch block so the comparison is final, and before the coverage ratchet so
# this tool's coverage row is on the ledger when the ratchet reads it. No 2>&1 / 2>$null on the child (under
# EAP=Stop a native child's first stderr line becomes a terminating throw), capture then read $LASTEXITCODE.
try {
  $rwPath = Join-Path $root 'build-rescue-worklist.ps1'
  if (Test-Path $rwPath) {
    $rwOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $rwPath -OutDir $OutDir
    $rwRc  = $LASTEXITCODE
    foreach ($l in @($rwOut)) { Log ('rescue-worklist: ' + $l) }
    if ($rwRc -eq 1) {
      # [regex]::Match, NOT -match + $Matches: $Matches is GLOBAL and this file reads it elsewhere.
      $rwWork = 0
      foreach ($rwM in [regex]::Matches((@($rwOut) -join "`n"), 'DROPPED (\d+)\s+UNTRACEABLE (\d+)\s+EXPIRING (\d+)\s+STALE (\d+)')) {
        for ($rwG = 1; $rwG -le 4; $rwG++) { $rwWork += [int]$rwM.Groups[$rwG].Value }
      }
      $rwN = if ($rwWork -gt 0) { [string]$rwWork } else { 'some' }
      $summary += ('REVIEW    rescue-worklist: capture work exists for the walled stores (' + $rwN + ' cell(s)) - see out\rescue-terms-*.txt (DROPPED/EXPIRING cells will leave the board if not captured)')
    }
    elseif ($rwRc -eq 3) {
      $summary += 'REVIEW    rescue-worklist could not evaluate - the walled-store freshness check proved nothing this cycle, so no browser worklist can be trusted'
    }
    elseif ($rwRc -ne 0) {
      Log ("rescue-worklist: DID NOT RUN - exit $rwRc with " + @($rwOut).Count + ' output line(s)')
      $summary += 'REVIEW    rescue-worklist did not complete - walled-store capture priorities went uncomputed this cycle'
    }
  }
} catch { Log ('rescue-worklist threw: ' + $_.Exception.Message) }

# ---- FF PULL-COMPLETENESS GUARD, AFTER THE PUBLISH (moved off the ship path 2026-09-19) ------------
# Catch a term the Freshop pull silently dropped (rate-limit -> 0 items) for a product FF actually carries
# (the 2026-07-13 ground-pork bug; coverage-gaps cannot see a never-pulled item). It re-probes Freshop LIVE,
# which is why it belongs here: measured 2026-09-19 it spent 118 s of a 726 s ship path holding the live
# board behind an advisory watch that can never block a publish. It keeps its own `if ($serverDue)` so the
# days it runs on are exactly the days it ran on before, and it stays AHEAD of audit-coverage-ledger
# (below), which is the check that would call its row stale. The argument line below still sits after the
# -NoPull block's closing brace, which is the property test-auditors pins structurally - and this comment
# deliberately does not spell that variable's name, because two of those cases locate the caller by
# searching the source for the literal token and would read this prose instead of the code.
if ($serverDue) {
  try {
    $fcArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-ff-carry.ps1'),'-OutDir',$OutDir)
    if (-not $NoAlert) { $fcArgs += '-Alert' }
    # CAPTURE, THEN LOG, THEN CHECK THE EXIT CODE. Piping the child straight into Log means a child that
    # dies before its first Write-Output logs NOTHING - and a guard that says nothing is indistinguishable
    # from one that was never wired up. That is not hypothetical: audit-ff-carry threw on its report line
    # on every run from 2026-07-13, and the string 'ff-carry' appears 0 times in 2,716 lines of
    # ad-cycle-log.txt. A native child's crash is not a PowerShell exception, so the catch below never saw
    # it either. This guard prints exactly one line whenever it completes, so zero lines IS the failure.
    # No 2>&1: $ErrorActionPreference is 'Stop' here, and redirecting a native child's stderr under Stop
    # turns its first stderr line into a terminating throw that would skip this very check.
    $fcOut = & powershell @fcArgs
    $fcRc  = $LASTEXITCODE
    foreach ($l in @($fcOut)) { Log ('ff-carry: ' + $l) }
    # Exit 3 is the estate's could-not-evaluate code and must NOT be reported as a crash. ff-carry returns
    # it when Freshop answered none of the terms it needed to probe: the script ran fine and said so, it
    # just proved nothing. Both cases leave the watch blind for the cycle, but only one of them means
    # "go read stderr", and sending someone to an empty stderr is how a real crash stops being believed.
    if ($fcRc -eq 3) {
      $summary += 'REVIEW    audit-ff-carry could not evaluate (Freshop refused every probe) - FF pull-drop victims went unchecked this cycle'
    }
    elseif ($fcRc -ne 0 -or @($fcOut).Count -eq 0) {
      Log ("ff-carry: DID NOT RUN - exit $fcRc with " + @($fcOut).Count + ' output line(s); the FF pull-drop watch is blind this cycle (see stderr)')
      $summary += 'REVIEW    audit-ff-carry did not complete - FF pull-drop victims went unchecked this cycle'
    }
  } catch { Log ('ff-carry guard threw: ' + $_.Exception.Message) }
}

# ---- RETENTION, AFTER EVERY READER OF "THE NEWEST comparison-*" HAS RUN ----------------------------
# Moved here 2026-08-22 with the ship/inspect split. prune-out and prune-intermediates DELETE dated files;
# arrivals-docket, capture-eviction, board-reconciliation and everyday-mismatch each resolve "the newest
# comparison-*" (and their own dated inputs), so retention now runs after all four - and still BEFORE
# test-auditors, because a deletion that blinds a watcher has to say so the same day it happened.
# Gated on $script:DownstreamRan so the condition is unchanged from when it lived inside the downstream
# block: it prunes only on a day the downstream actually ran, never after a hard-failed pull.
if ($script:DownstreamRan) {
  # ---- RETENTION (2026-08-08): cap out\'s dated-family growth. Conservative per-family windows set past
  # the deepest historical reader (see prune-out.ps1's header); evidence dirs are never listed. Non-fatal.
  try {
    $pr = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'prune-out.ps1') -Apply
    foreach ($l in (@($pr) | Select-Object -Last 1)) { Log ('prune-out: ' + $l) }
  } catch { Log ('prune-out threw: ' + $_.Exception.Message) }
  # THE OTHER HALF OF RETENTION (wired 2026-08-21). prune-out caps the dated FAMILIES in out\;
  # prune-intermediates caps the gitignored per-run scratch (candidates-<date>.json and siblings),
  # which no reader ever opens except the newest. It was written on 2026-08-21 against 408 MB growing
  # ~19 MB/day and shipped with NO production caller, so the growth it was written to stop carried
  # right on - the script census caught it as an orphan. Keep 3, matching its own default. Non-fatal.
  try {
    $pi = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'prune-intermediates.ps1') -Keep 3
    foreach ($l in (@($pi) | Select-Object -Last 1)) { Log ('prune-intermediates: ' + $l) }
  } catch { Log ('prune-intermediates threw: ' + $_.Exception.Message) }
}
