# bot-paths.ps1 - THE one declaration of what an automated commit in this repo is allowed to touch.
#
# WHY THIS EXISTS (2026-09-06, PLAN-top5-2026-09-06 area 3). This tree is shared: scheduled jobs, headless
# agents and interactive sessions all edit it at the same time. An automated commit that stages by SWEEP
# therefore commits whatever a person had half-written. The estate has paid for that four times:
#
#   2026-07-23  the walmart flood
#   2026-08-22  d2a864c0 - 4,388 files / 797,640 insertions, 191 MB of seeded Chrome cookies
#   2026-08-25  0c47012c - the F2 unit swept in by a shared index
#   2026-09-05  3c44d0c1 - push-data.ps1's `git add -A` put 325 files on main, 192 of them .ps1 files
#               MID-EDIT, 27 of which threw at startup. main held that for 59 minutes.
#
# capture-run.ps1 got the right answer for itself on 2026-08-22 - "STAGE PIPELINE-OWNED PATHS ONLY - NEVER
# git add -A" - and wrote its ownership list inline. push-data.ps1 never got it, and a list that lives
# inside one consumer cannot be enforced against another. So the list moves HERE, once, and three things
# read it: capture-run's publish stage, push-data.ps1, and ops\verify-bot-commit-scope.ps1, which the
# pre-commit hook runs so that a bot commit outside this list is REFUSED rather than merely discouraged.
#
# TWO SETS, BECAUSE THEY CARRY DIFFERENT PROOF (2026-08-22, moved here verbatim with their reasons).
# INPUTS are what a store told us: raw captures, the schedules and ledgers derived from them, the logs.
# They are evidence and are always worth committing - a capture-only ad run has nothing else to say.
# SERVED are what a READER gets: public\** (Cloudflare deploys it from the repo) and the meal-prep files
# the recipe cards price from. Those may be staged ONLY by a run that actually built them AND passed the
# gate, because export-feed writes public\smp-feed.json BEFORE guards run: a board guards REJECTED would
# otherwise still ship its feed to the edge, and every recipe card prices off that feed.
#
# ADDING A PATH IS A DECISION SOMEBODY DEFENDS IN A DIFF. The failure mode of a too-SHORT list is that a
# writer's output sits dirty on a shared tree until someone sweeps it by hand (2026-09-02, 536 files), and
# the served-dirty block in capture-run plus push-data's own leftover report are what make that VISIBLE
# rather than silent. The failure mode of a too-LONG list is 3c44d0c1. Visible-and-short beats silent.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\bot-paths.ps1')
# Self-test:   powershell -File lib\bot-paths.ps1 -SelfTest
#
# NO param() BLOCK HERE, DELIBERATELY - same reason as lib\json-io.ps1 and lib\guard-contract.ps1. In
# PS 5.1, dot-sourcing a script runs its param() block in the CALLER's scope, so a param([switch]$SelfTest)
# here would reset the caller's own -SelfTest to $false on the line after it bound, silently disarming its
# self-test. Read the switch off $args, and only when this file is RUN rather than dot-sourced.
$__botPathsSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Get-BotInputPaths {
  <# Repo-relative, forward slashes, the form `git add -A -- <path>` takes. #>
  # THE COMMA IS LOAD-BEARING: a PowerShell function unrolls a collection on return, and every caller
  # concatenates this with another array. See lib\json-io.ps1's note; the estate has paid for it once.
  return ,@(
    'grocery/out',
    'grocery/ad-cycle-log.txt', 'grocery/alert-log.txt', 'grocery/ff-sweep-log.txt',
    'grocery/ad-schedule.json', 'grocery/price-history.json', 'grocery/product-urls.json',
    'grocery/sale-windows.json', 'grocery/rollback-first-seen.json',
    # THE CARRIAGE LEDGERS (Brad's ruling, 2026-08-27): "if we find a price for an ingredient, it should
    # always be merged after discovery on the seven stores."
    #
    # These five were on NO staging list - not $inputPaths, not $servedPaths, not push-data.ps1's sweep -
    # so every carriage verdict since 2026-08-25 sat in the working tree only. Measured the day the line
    # was added: carriage.json held 20 bids at HEAD and 59 in the tree. THIRTY-NINE CARRIED verdicts, from
    # three sessions across three days, one `git checkout -- .` from gone and invisible in `git log`
    # because the tracked file had not moved since 08-25.
    #
    # A CARRIAGE VERDICT IS AN OBSERVATION, NOT A COMPUTATION. Rule B turns on what a store carried at a
    # moment; re-creating one means re-driving seven stores, and the moment itself cannot be re-visited.
    # Six scripts read carriage.json - including engine\cost-recipes.ps1 and engine\publish.ps1 - so an
    # unmerged verdict also means a clean clone prices from a different world than this box does.
    #
    # They belong in INPUTS, not SERVED: they are evidence of what a store told us, which is exactly what
    # this list is for, and they must ship on a capture-only ad run that builds no board. On a quiet day
    # these write identical bytes and stage nothing.
    'grocery/carriage.json', 'grocery/ingredient-queue.json',
    'grocery/board-price-overrides.json', 'grocery/sale-without-ad.json',
    'grocery/notify-log.txt',
    # THE PUBLISHER LEDGER (2026-08-27). harvest and the sourcing agents learn which domains serve
    # robots.txt, allow us, and carry a usable nutrition panel - and that knowledge was on no staging list.
    # One probe added THIRTEEN new publishers (masonfit, eatingbirdfood, feelgoodfoodie and ten more) and
    # every one of them existed only in this working tree. Re-earning it means re-probing the open web, so
    # it is evidence in exactly the sense this list means.
    'meal-prep/db/source-domains.json',
    # THE PRODUCT IDENTITY TABLE. It is regenerated every morning, so if it is not staged here it never
    # leaves this PC - which is exactly the last-mile failure found on 2026-08-22 (public\board.json
    # rebuilt daily, last bot commit four days old). It also has to be tracked for the table to exist in
    # the cloud at all: daily.yml clones clean and rebuilds graph.db from tracked JSON, so an untracked
    # table means an empty index there. On a quiet day the emitter writes identical bytes and this stages
    # nothing.
    'graph/identity',
    # THE AUDIT RECORD, WHICH WE WERE DROPPING WHILE KEEPING 191 MB OF COOKIES (2026-08-23). .gitignore:106
    # states the rule outright - "provenance JSONL ARE tracked: they are the evaluation record and the
    # audit" - and then this list never staged them, so graph\provenance\2026-08-22.jsonl and -23 sat
    # untracked and 08-21 sat modified and uncommitted. Same reason, same fix, one line later than it
    # should have been.
    'graph/provenance'
  )
}

function Get-BotServedPaths {
  <# Repo-relative, forward slashes. Staged ONLY by a run that built them AND passed guards. #>
  return ,@(
    'public',
    'meal-prep/db/costed.json', 'meal-prep/db/cost-flags.txt',
    'meal-prep/pipeline/v2-perserving.json', 'meal-prep/pipeline/v2-perserving.prev.json',
    'meal-prep/pipeline/v2-inversions.json',
    'meal-prep/free-rotation.json', 'meal-prep/ingredient-map.json',
    'meal-prep/recipes-db.json',
    # WHAT THE CHAIN REWRITES AFTER GUARDS, ADDED 2026-09-02 (queue 2026-09-02-reanch1). The list was
    # enumerated from "the exact set real bot commits have ever touched" (2026-08-22) at a time when
    # reanchor-all and the three surface builders had not yet joined the chain. A staging allowlist cannot
    # see a new writer. The writers, by name: check-ad-cycles:774 reanchor-all ("re-anchored cost_ps +
    # costPerServing on 584 specs") and check-ad-cycles:1162 build-cheapnow/dinner/stretcher-data + the
    # tool splice. The incident: the bot commit 91f895ef touched graph/, grocery/ and out/ only, and 536
    # rewritten files then had to be swept by hand, unlabelled, as 26c2b0e0.
    'meal-prep/db/recipes',
    'meal-prep/cheapnow-data.js', 'meal-prep/dinner-data.js', 'meal-prep/stretcher-data.js',
    'site/tools/cheap-dinners-tool.html', 'site/tools/dinner-tonight-tool.html',
    'site/tools/payday-stretcher-tool.html'
  )
}

function Get-BotGlobPaths {
  <# Owned paths that are ROTATING file names rather than fixed ones. capture-run stages these with their
     own `git add` because git EXITS NONZERO on a pathspec matching nothing; the scope check needs to know
     they are owned so a legitimate bot commit carrying one is not refused. #>
  return ,@('grocery/alert-sent-*.txt')
}

function Test-BotPathOwned {
  <# Is one repo-relative path (either slash style) inside the declared ownership set?
     A DIRECTORY ENTRY OWNS ITS SUBTREE, and nothing else. 'grocery/out' owns 'grocery/out/regular/x.json'
     and does NOT own 'grocery/outbound.json' - the boundary is the slash, not the prefix, which is the
     difference between an ownership list and a `-like` that happens to match. #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [string[]]$Owned
  )
  if (-not $PSBoundParameters.ContainsKey('Owned')) {
    $Owned = @((Get-BotInputPaths) + (Get-BotServedPaths) + (Get-BotGlobPaths))
  }
  $p = $Path.Replace('\', '/').TrimStart('./')
  foreach ($o in $Owned) {
    $n = $o.Replace('\', '/').TrimEnd('/')
    if ($n -match '[*?]') { if ($p -like $n) { return $true }; continue }
    if ($p -eq $n) { return $true }
    if ($p.StartsWith($n + '/')) { return $true }
  }
  return $false
}

if ($__botPathsSelfTest) {
  $fail = 0
  function BpT([string]$m, [bool]$cond) {
    if ($cond) { Write-Output ('  PASS  ' + $m) } else { Write-Output ('  FAIL  ' + $m); $script:fail++ }
  }

  $inp = Get-BotInputPaths
  $srv = Get-BotServedPaths

  # THE ARRAY-NESS THE COMMA BUYS. Both callers do `@($inputPaths + $servedPaths)`; a scalar return would
  # concatenate a STRING and stage one path. Asserted, not assumed - this is the defect-6 shape.
  BpT 'Get-BotInputPaths returns an array, not an unrolled scalar' ($inp -is [array] -and $inp.Count -gt 10)
  BpT 'Get-BotServedPaths returns an array, not an unrolled scalar' ($srv -is [array] -and $srv.Count -gt 5)

  # THE LEDGERS THAT WERE LOST. Each of these was on NO list once, and the loss was unrecoverable by
  # re-running anything. A regression here is not a style change.
  foreach ($need in @('grocery/out', 'grocery/carriage.json', 'grocery/ingredient-queue.json',
                      'grocery/board-price-overrides.json', 'grocery/sale-without-ad.json',
                      'meal-prep/db/source-domains.json', 'graph/identity', 'graph/provenance')) {
    BpT ("INPUTS still names $need (a lost observation cannot be re-derived)") ($inp -contains $need)
  }
  foreach ($need in @('public', 'meal-prep/db/recipes', 'meal-prep/cheapnow-data.js',
                      'meal-prep/dinner-data.js', 'meal-prep/stretcher-data.js')) {
    BpT ("SERVED still names $need (the chain rewrites it after guards)") ($srv -contains $need)
  }

  # THE TWO SETS MUST NOT OVERLAP: served is gated on the guard verdict and inputs are not, so a path in
  # both would ship a rejected board's output under the inputs gate.
  $both = @($inp | Where-Object { $srv -contains $_ })
  BpT 'INPUTS and SERVED are disjoint (a path in both escapes the guard gate)' ($both.Count -eq 0)

  # ---- Test-BotPathOwned: the predicate the pre-commit hook refuses on --------------------------------
  BpT 'MUST FIRE: a .ps1 at the repo root is NOT owned (this is 3c44d0c1, 192 files)' `
      (-not (Test-BotPathOwned -Path 'grocery/push-data.ps1'))
  BpT 'MUST FIRE: a source file two levels down is NOT owned' `
      (-not (Test-BotPathOwned -Path 'meal-prep/pipeline/harvest-crawl.ps1'))
  BpT 'MUST FIRE: a design doc is NOT owned (real push-data commits swept design\ in)' `
      (-not (Test-BotPathOwned -Path 'design/MASTER-PLAN-RESTRUCTURE.md'))
  BpT 'CLEAN TWIN: a file under an owned DIRECTORY is owned' `
      (Test-BotPathOwned -Path 'grocery/out/regular/2026-09-06.json')
  BpT 'CLEAN TWIN: an owned FILE is owned' (Test-BotPathOwned -Path 'grocery/carriage.json')
  BpT 'CLEAN TWIN: backslashes are the same path' (Test-BotPathOwned -Path 'grocery\out\regular\x.json')
  BpT 'CLEAN TWIN: a rotating alert-sent file is owned by its glob' `
      (Test-BotPathOwned -Path 'grocery/alert-sent-2026-09-06.txt')
  # THE BOUNDARY IS THE SLASH, NOT THE PREFIX. A plain StartsWith would hand 'grocery/out' ownership of
  # every path beginning with those characters, which is how an ownership list quietly becomes a sweep.
  BpT 'MUST FIRE: a sibling whose name merely STARTS with an owned directory is NOT owned' `
      (-not (Test-BotPathOwned -Path 'grocery/outbound-notes.md'))
  # A caller may pass its own set; passing an EMPTY set must own nothing, never everything.
  BpT 'MUST FIRE: an empty ownership set owns nothing (an unreadable list is not a skeleton key)' `
      (-not (Test-BotPathOwned -Path 'grocery/out/x.json' -Owned @()))

  if ($fail) { Write-Output "BOT-PATHS SELF-TEST FAILED ($fail)"; exit 1 }
  Write-Output 'BOT-PATHS SELF-TEST PASSED (both lists array-shaped and complete, the sets disjoint, ownership bounded by the slash)'
  exit 0
}
