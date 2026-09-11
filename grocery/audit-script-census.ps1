<#
  audit-script-census.ps1 - every .ps1 in this tree is either called by code, or NAMED here as a deliberate
  human entry point. Nothing is allowed to be merely unreachable.

  WHY (2026-07-30): of the 181 .ps1 under grocery\ (archive\ excluded), 69 were named by no other executable
  file in the repo, and 37 of those sat inside out\ - the pipeline's own OUTPUT directory, where every glob,
  grep and directory listing trips over them. One file in five was unreachable, and at that ratio a listing
  stops being information: promote-verdicts.ps1 (run by hand, writes exclude-provenance.json) looked exactly
  like drop-stale-overrides.ps1 (a finished 2026-07-14 one-shot that would clobber a backup if re-run).

  UNCALLED IS NOT DEAD. Seven of these are launched by hand from a scheduled-agent SKILL, and the SKILLs live
  in ~\.claude\scheduled-tasks\, outside this repo - they are unreferenced here BY CONSTRUCTION and always
  will be. familyfare-sweep.ps1 is launched by Windows Task Scheduler through the generic run-hidden.vbs, so
  its name appears nowhere either. That is why this is a RATCHET against a recorded set, never a hard zero:
  $KNOWN is the written statement of which uncalled scripts are uncalled on purpose, and WHY. Adding a line
  to it is a decision someone has to defend in a diff. That is the entire mechanism.

  TWO INVARIANTS
    1. SET   - no uncalled script outside out\ that is absent from $KNOWN.  (a new orphan appeared)
    2. COUNT - no more .ps1 under out\ than $OutBaseline.                   (a new one-off was dropped in
               the output directory; the number may only be lowered, by archiving them)

  Reference universe is EXECUTABLE files only (.ps1/.psm1/.js/.yml/.yaml/.vbs/.bat/.cmd). Prose is not a
  caller: a script named only in a README or an audit write-up is still unreachable, and counting that as a
  reference would make the whole census evaporate the day the write-up is archived. archive\ is excluded on
  BOTH sides - a reference from archive is a dead reference. So is a NESTED CHECKOUT: see the boundary walk
  below for why a git worktree is a copy of this repo and not a second set of scripts.

  Exit 0 = clean, 2 = a new orphan or a new out\ one-off, 3 = could not evaluate (never read that as "ok").
  Usage: audit-script-census.ps1 [-Root <dir>] [-ScanRoot <repo>] [-OutBaseline <n>]
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param(
  [string]$Root,                  # dir whose .ps1 are the population   (default: this script's dir)
  [string]$ScanRoot,              # dir whose exec files are searched    (default: the repo above $Root)
  [int]$OutBaseline = -1,         # max .ps1 allowed under $Root\out\    (default: the frozen baseline below)
  [switch]$WideBaseline,          # record the wide tier's high-water mark (I85 rung 2); refuses to RAISE it
  # A TREE WITH NO GATED SUBTREE (2026-09-09). The two-tier split below is a property of THIS repo -
  # grocery\ is hard-gated, everything else is ratcheted - and it is applied to paths relative to -Root.
  # A scoped run over any OTHER tree therefore has no strict tier at all, and three frozen must-fire
  # fixtures had been silently unable to fire ever since the wide tier was added: their orphan landed in
  # the WIDE tier, one against a high-water mark of 73, and one is not more than 73.
  #
  # A SWITCH RATHER THAN A -StrictPrefix '' STRING, and that is not taste. AN EMPTY STRING ARGUMENT DOES
  # NOT SURVIVE THE NATIVE-EXE BOUNDARY: powershell.exe -File drops it, the next token binds to the
  # parameter instead, and the child exits 1 on a binding error. Measured here before shipping, which is
  # the only reason this is a switch.
  [switch]$WholeTreeIsStrict
)
$ErrorActionPreference = 'Stop'
# THE POPULATION IS THE WHOLE REPO SINCE 2026-09-09 (backlog I85 rung 2). It defaulted to this script's
# own directory, so 72 scripts under .claude\, meal-prep\, site\, ops\, media\ and sidecar\ were
# examined by nothing at all - and the output said "273 script(s) read against 632 executable files",
# which reads as estate-wide. Widening it is safe only because the wide tier is a RATCHET; see the
# two-tier note further down.
if (-not $ScanRoot) { $ScanRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) } }
$ScanRoot = $ScanRoot.TrimEnd('\')
if (-not $Root)     { $Root     = $ScanRoot }
$Root = $Root.TrimEnd('\')
$ScanRoot = $ScanRoot.TrimEnd('\')
# FROZEN 2026-07-30 at 37: measured count of .ps1 under grocery\out\. May only go DOWN (archive them).
# RAISED to 38 on 2026-08-20, once - and the reason matters, because raising a ratchet to make it green is
# normally the wrong move. out\vsample-2026-08-15\merge-findings.ps1 landed with commit 65149ad9 (the weekly
# accuracy sample) and cannot be archived: it resolves its own directory from $MyInvocation and merges the
# per-store CSVs sitting BESIDE it, writing to the parent. Moving it to archive\one-off\ would break it,
# so the choice was a permanently-red gate or an honest ceiling. If a 39th appears, that one is new debris -
# archive it rather than raising this again.
if ($OutBaseline -lt 0) { $OutBaseline = 38 }

# FROZEN 2026-07-30, appended to since - the scripts nothing in the repo calls, each with the reason it
# stays. An entry that stops being uncalled (wired in, or archived) prints a note telling you to delete the
# line; it never fails. No count is written here: it drifted from 25 to 39 before anyone noticed.
$KNOWN = [ordered]@{
  # -- OUTSIDE grocery\, recordable here since 2026-09-09 (backlog I85 rung 2). Before the population
  #    widened there was literally nowhere to write these down, which the item named as unresolved.
  'ops\merge-backlog-inbox.ps1'      = 'BY HAND, and uncalled on purpose. It merges design\backlog-inbox\*.md into design\BACKLOG-course-findings.md, allocating ids as it goes. Id allocation is a one-writer operation - two runs racing would mint the same id twice - and the merge is a judgement about whether a course agent''s finding is really new. A scheduled run would do both unattended. It was the script whose orphan status could not be recorded anywhere, which is how backlog I85 was found.'
  'ops\cpu-load.ps1'                 = 'BY HAND, or by a session''s load-test harness, and uncalled on purpose (Brad, 2026-09-11). It is the only sanctioned way to put deliberate CPU load on this shared box: it takes its cores all-or-nothing from the machine-wide budget run-gates uses, refuses more than that or longer than 15 minutes, and its burners stop on a stale heartbeat if it is killed. Nothing in the repo should run load on a schedule, so no file here calls it; ops\audit-cpu-load.ps1 names it as the compliant way.'
  # -- manual investigation tools, run by a human when a question needs answering
  'grocery\probe-price-fields.ps1'           = 'PHASE 0 of PLAN-live-price-state: asks each of the 9 price sources whether it states that a discount is live and when it ENDS, and writes the raw payloads to out\audit\price-fields\ as evidence. Answered its question on 2026-08-21 (Baker''s and Family Fare publish windows; five stores do not). Re-run by hand when a store changes its API - it makes assertions about the world, not about our data, so a scheduled run would just re-download the same answer daily.'
  'grocery\reanchor-rollback-ledger.ps1'     = 'ONE-OFF MIGRATION, by hand (2026-08-22): moved rollback-first-seen.json first_seen anchors back to the capture as_of per Brad''s ruling that the 30-day TTL runs from DETECTION. Idempotent and -WhatIf-able; kept so the migration is reproducible and documented, never scheduled - Get-RollbackWindow -AsOf now does this on every build.'
  'grocery\backfill-aldi-link-urls.ps1'      = 'ONE-OFF REPAIR, by hand (2026-09-11): stamps link_url onto the Aldi rows built 2026-08-25..2026-09-10 with none (the relative-href defect fixed in 04727f04c), by rebuilding each row''s own as_of capture through build-aldi-regular''s Invoke-Build and matching exact item+size+price. Dry run by default, -Apply explicit. Never scheduled: once applied, carry-forward moves the links forward on its own and the window rows retire under the quarterly rotation, so a second run finds nothing to do.'
  'grocery\chain-idle.ps1'                   = 'called by the 09:00 STAGE-TWO AGENT, which lives in ~\.claude\scheduled-tasks\ and not in this repo, so no file here can name it. It answers one question - is a capture-run chain holding the mutex right now - and it is a FILE rather than an inline check because the inline version was mangled by quoting on first writing (''Global	c-capture-run'' became a literal tab). A named-mutex check that silently tests the WRONG name always answers FREE, and FREE is the answer that causes the damage: stage two would build straight into the middle of the 0800 chain, both writing outegular and touching the same git index.'
  'grocery\seed-profile-from-chrome.ps1'      = 'BY HAND, once per store, and never scheduled (Brad, 2026-08-22: "Why cant YOUR chrome use MY profile?"). Copies his live session into a driver profile because Chrome hard-locks a User Data directory to one running instance, so a launch pointed at his profile while his Chrome is open exits silently and never opens its debug port. It handles a real logged-in session, so it stays a deliberate, attended act rather than something a daily job can decide to do.'
  # -- launched by hand from a scheduled-agent SKILL under ~\.claude\scheduled-tasks\ (not in this repo)
  'grocery\build-aldi-regular.ps1'           = 'SKILL grocery-browser-stores-refresh step F2 - weekly Aldi capture builder'
  'grocery\build-pull-order.ps1'             = 'SKILL grocery-browser-stores-refresh - priority term order for the walled stores'
  'grocery\notify-desktop.ps1'               = 'SKILL grocery-browser-stores-refresh - operator toast during the browser run'
  'grocery\resolve-chips-hyvee.ps1'          = 'SKILL grocery-browser-stores-refresh - Hy-Vee link chips'
  'grocery\capture-sink.ps1'                 = 'SKILL grocery-browser-stores-refresh step 2 - the localhost file drop the attended-Chrome capture page POSTs its CSV to, because the browser tool channel truncates a returned string at ~1KB and a store sweep is 40-60KB. Uncalled here BY CONSTRUCTION: the caller is the agent''s own background command line, and the SKILL that carries it lives in ~\.claude\scheduled-tasks\. It is committed rather than hand-written each run ON PURPOSE - the throwaway it replaced was headed "CSV exfil receiver" and explained how a form POST defeats walmart.com''s CSP, which is the likeliest reason a safety check refused the browser tools for the rest of the 2026-08-25 run. The SKILL now tells the operator to use this one and not write another; deleting it would restore the practice that cost that run its whole browser half.'
  'grocery\fareway-daily-due.ps1'            = 'SKILL grocery-fareway-daily-check - due gate'
  'grocery\select-fareway-shop.ps1'          = 'SKILL grocery-fareway-daily-check - Omaha store picker'
  'grocery\pull-fareway-ads.ps1'             = 'SKILL grocery-fareway-daily-check + browser-stores-refresh; stamped into ad-schedule.json'
  # -- launched by Windows Task Scheduler DIRECTLY (the task's action names the .ps1, so nothing in the
  #    repo does). Verified 2026-08-20 against Get-ScheduledTask; if a task is ever deleted, delete its
  #    line here too, or this table starts excusing a script that genuinely nothing runs.
  'grocery\capture-run.ps1'                  = 'scheduled tasks "TC Grocery Ad Pulls 0700" (-Kind ad) and "TC Grocery Daily Capture 0800" (-Kind daily) - the concurrent seven-store capture runner'
  'grocery\capture-watchdog.ps1'             = 'scheduled task "TC Grocery Capture Watchdog 1030" (-Alert; named 0930 until 2026-09-07, when ops\install-grocery-tasks.ps1 -FixName renamed it to match the 10:30 it has run at since 2026-08-31) - checks the 0700/0800 jobs actually captured AND published, rather than merely exiting 0'
  # -- launched by Windows Task Scheduler through the GENERIC run-hidden.vbs, so no file names it
  'grocery\familyfare-sweep.ps1'             = 'scheduled task "SMP Family Fare Term Sweep", every 3h via run-hidden.vbs'
  'grocery\send-friday-email.ps1'            = 'scheduled task "SMP Friday Email (draft)", weekly via run-hidden.vbs; drafts unless -Send, and a week_of stamp stops a double-mail'
  # -- human entry points, run when a specific failure or a specific job shows up
  'grocery\ingredient-queue.ps1'             = 'Recipe Hunter Rule B queue (an ingredient is CARRIED once ANY of the 7 stores has it; NOT-CARRIED only when all 7 were CHECKED and none do). WIRED IN 2026-08-22: hunt-run.ps1 reads its verdicts, and -Promote writes settled ones into grocery\carriage.json where the cost engine and the publish gate read them through lib\carriage-lib.ps1. It was uncalled for a week, and in that week four recipes whose ingredient no Omaha store stocks reached live paid pages - the gate existed and nothing ran it.'
  'grocery\promote-ingredient-queue.ps1'     = 'by hand, and deliberately NOT on the daily chain: it writes engine inputs from ingredient-queue-map.json, which is a RULING about commodity identity that a human has to make. Auto-running it would let whatever is in the map file price the board unreviewed, and a careless id splits a commodity already priced under another name. Its fixtures DO run every suite (audit-graph-gates sits beside it in test-auditors); it is the -Apply that stays manual.'
  'grocery\promote-verdicts.ps1'             = 'weekly by hand after audit-match-soundness; writes exclude-provenance.json'
  'grocery\adjudicate-blind-findings.ps1'    = 'weekly by hand inside the accuracy sample - opens the sealed key AFTER the blind findings are frozen, which is the whole point (a caller could run it early)'
  'grocery\new-commodity.ps1'                = 'by hand per commodity added - clones a sibling exclude and asks for the band, so it is an operator prompt, not a batch step'
  'grocery\set-board-cell.ps1'               = 'BY HAND, per adjudicated wrong-product cell on the RECIPE board (out\recipe-board-everyday.json). It corrects or removes ONE store cell and nothing else, which is the one edit add-recipe-board-rows -Replace cannot make: -Replace demands item+size+price on EVERY cell and so silently DROPS the per-unit-only cells - 349 of them at 2026-08-29, and export-feed confirms they reach smp-feed.json and are shown to shoppers. It is an operator act, not a batch step, because the input is a human ruling about which product a row is FOR; -Evidence is mandatory and a crown change is refused unless asked for out loud. Its main-board twin is add-known-wrong.ps1, which compare-deals enforces on every build. Its 27-case -SelfTest IS wired in and runs under run-gates.'
  'grocery\audit-ff-missing-products.ps1'    = 'report half of the FF partial-pull pair; the -Apply half is heal-ff-missing-products.ps1'
  'grocery\triage-outofband.ps1'             = 'sub-diagnoses the OUT-OF-BAND bucket of triage-coverage-gaps.ps1'
  'grocery\triage-unpriced.ps1'              = 'sub-diagnoses the UNPRICED bucket of triage-coverage-gaps.ps1'
  'grocery\verify-no-regression.ps1'         = 'run before/after a commodity include edit - the first-match-wins theft check'
  'grocery\diag-ff.ps1'                      = 'Freshop term/match diagnostic, -Ids <id...>'
  'grocery\test-unitprice.ps1'               = 'per-unit math bench, run while editing pu-lib.ps1'
  'grocery\build-drift-chips.ps1'            = 'browser link pass - chips whose link points at the WRONG product (sibling of build-nolink-chips.ps1)'
  'grocery\transform-store-links.ps1'        = 'browser link pass - generic successor to archive\transform-bakers-links.ps1'
  'grocery\stamp-fareway-instore.ps1'        = 'stamps Fareway price_mode after a manual shelf verification'
  'grocery\recover-sams-quarantine.ps1'      = "recovers a quarantined Sam's capture"
  'grocery\get-tiers.ps1'                    = 'Ghost tier lookup, used while editing the join interstitial'
  'grocery\cutover-feed-url.ps1'             = 'one command to move the public Worker base URL everywhere (source + a rebuild/republish checklist); run by hand on a Cloudflare account move or custom-domain change - last used 2026-08-08 for feed.thriftycrew.com'
  # -- semantic coverage backlog (2026-08-01): the sweep finds gaps, these three work them by hand
  'grocery\explain-coverage-gap.ps1'         = 'diagnoses WHY a swept product is invisible (NO-INCLUDE / EXCLUDED / CLAIMED / MATCHES) before any rule is touched'
  'grocery\apply-coverage-batch.ps1'         = 'applies + GATES one batch of commodity include widenings; reverts itself on a batch-attributable tile fault'
  'grocery\withdraw-stale-link.ps1'          = 'removes a stored product URL that no longer describes its cell, at a store with no headless resolver'
  'grocery\aisle-test.ps1'                   = 'gates a crown flip on the store''s own shelf department; also -LiveBoard, wired daily in check-ad-cycles'
  'grocery\discover-hyvee.ps1'               = 'F1 Hy-Vee discovery: bounded rotating search pass writing a REVIEW DOCKET of net-new candidates that beat what we hold; never writes the feed'
  # -- staples-500 per-batch pipeline (batch 1 of 10 done; run once per batch, by hand)
  'grocery\prime-batch-headless.ps1'         = 'staples-500 per-batch primer'
  'grocery\merge-candidates.ps1'             = 'staples-500 per-batch candidate merge'
  # -- member-tool data builds, on demand after a recipe/price change
  'grocery\build-freezer-data.ps1'           = 'data build for the freezer-math tool'
  'grocery\build-sams-data.ps1'              = "data build for the Sam's tool"
  'grocery\build-staples-data.ps1'           = 'data build for the my-staples watchlist'
  # -- brand-pricing pilot, parked pending Brad's scale decision
  'grocery\brands\make-config.ps1'           = 'brand-pricing pilot'
  'grocery\brands\gen-browser-cfg.ps1'       = 'brand-pricing pilot'
  'grocery\brands\pull-ff-brands-batch.ps1'  = 'brand-pricing pilot'
  'grocery\brands\assemble-board-brands.ps1' = 'brand-pricing pilot'
  'grocery\brands\regression-brands.ps1'     = 'brand-pricing pilot'
  # -- 2026-08-04 trend-page cut (492 pages -> 20). Run by hand, in this order, whenever the keep-list moves;
  # each derives its own target set from that keep-list rather than a typed list, so none is a spent one-shot.
  # They landed on 08-04 and went unnoticed for two days because THIS census was already red for an unrelated
  # reason - the four-day worktree failure above. That is the cost of a watcher nobody reads, measured.
  'grocery\build-trend-redirects.ps1'        = 'emits the Ghost redirects file for every retired trend page; re-run whenever the keep-list moves, because the upload replaces the WHOLE redirect set'
  'grocery\unpublish-trend-pages.ps1'        = 'drafts (never deletes) the retired trend posts; refuses to run until the redirects answer over HTTP, and is resumable'
  'grocery\publish-trend-index.ps1'          = 'publishes the trend index page; live successor to the archived one-off, with the tracked-count derived from the keep-list'
  # -- finished one-shots still in the tree on 2026-07-30. Both were verified to change ZERO records today
  # and both unconditionally rewrite live data plus a hardcoded 2026-07-14 backup name, so re-running one
  # DESTROYS that backup. Delete these two lines once they are in archive\one-off\.
}

# NESTED CHECKOUTS (2026-08-06). A git worktree is a second checkout of THIS repo: the same scripts, at a
# path that exists only while some other session is running. One appeared under grocery\ on 2026-08-03 and
# this census has been red every day since. The 35 ORPHANs it printed were the HARMLESS half. The real
# damage is that a checkout also holds a COPY of this file - and a copy is not $self, so it was read as a
# source, where its $KNOWN table quotes every recorded name and marked the entire recorded set "called".
# Measured 2026-08-06: population 144 -> 451, and of the 35 deliberate entry points this census exists to
# keep watching, it could still see ZERO. That is precisely the self-defeat the $self note below describes,
# arriving through a copy instead of through the file itself. A gate that can never arm.
#
# The boundary is the one git itself uses: a directory holding its OWN .git entry - a FILE in a worktree, a
# DIRECTORY in a clone or submodule - is a separate checkout, and it is pruned whole. Deliberately NOT a
# \.claude\worktrees\ path pattern: the four live worktrees already sit under two different parents, and the
# next one need not sit under either. Excluded on BOTH sides for the same reason archive\ is - a reference
# from a copy of the repo is not a reference, and would mask the orphan it copied.
#
# $Root and its ancestors are never pruned. The checkout we were ASKED to census is not someone else's copy;
# that exemption is what lets this run from inside a worktree at all (it is running in one right now).
function Get-CheckoutBoundaries {
  param([string]$from)
  $found = New-Object System.Collections.ArrayList
  $stack = New-Object System.Collections.Stack
  $stack.Push($from)
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
      if (@('.git','node_modules','archive') -contains $d.Name) { continue }
      # prune AT the boundary: a nested checkout's own subtree is never walked, so this stays cheap
      if (Test-Path -LiteralPath (Join-Path $d.FullName '.git')) { [void]$found.Add($d.FullName.TrimEnd('\')); continue }
      $stack.Push($d.FullName)
    }
  }
  ,$found
}
$walkFrom = @($ScanRoot)
if (-not ($Root + '\').StartsWith($ScanRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { $walkFrom += $Root }
# Collected with foreach, never through a pipeline: ,$found exists to stop unrolling, so an EMPTY result
# would survive a pipeline as one object and print as a nested checkout at the empty path.
$acc = New-Object System.Collections.ArrayList
foreach ($w in $walkFrom) {
  foreach ($b in (Get-CheckoutBoundaries $w)) {
    if (($Root + '\').StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }   # $Root or above it
    if (-not $acc.Contains($b)) { [void]$acc.Add($b) }
  }
}
$nested = @($acc | Sort-Object)
function Test-InOtherCheckout {
  param([string]$path)
  foreach ($b in $script:nested) { if ($path.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
  return $false
}

# -Filter *.ps1 is the legacy 8.3 matcher and also matches .ps1xml, so the extension is re-checked exactly.
$all = @(Get-ChildItem -Path $Root -Filter *.ps1 -Recurse -File -ErrorAction SilentlyContinue |
         Where-Object { $_.Extension -eq '.ps1' -and $_.FullName -notmatch '\\archive\\' -and
                        -not (Test-InOtherCheckout $_.FullName) })
# AN `out\` SEGMENT ANYWHERE, not just at the top of $Root (2026-09-09, backlog I85 rung 2). This test
# used to be anchored at the start of the $Root-relative path, which was right while $Root was
# grocery\. The moment the population widened to the repo, `grocery\out\...` stopped matching `^out\`
# and 38 one-off scripts that had always been excluded came back as ORPHAN findings - a day-one wall
# of red produced entirely by the widening, which is exactly what the ratchet design exists to avoid.
$pop  = @($all | Where-Object { $_.FullName.Substring($ScanRoot.Length + 1) -notmatch '(^|\\)out\\' })
# THE OUT-BASELINE STAYS SCOPED TO grocery\out\, which is the question it has always asked: has a
# one-off been written into THE PIPELINE'S output directory? Counting every `out\` in the repo would
# silently redefine a frozen baseline of 38 to mean something else, and the first symptom was this
# check failing at 39 for a file in another module's out\ - a number moving because its definition
# moved, which is the one way a baseline can lie.
# AND IT IS THE SAME REPO-SPECIFIC LITERAL THE TIERING USES, so it needs the same escape hatch. A tree
# with no grocery\ has no grocery\out\ either, so this matched nothing in a fixture and the out\ ratchet's
# must-fire could not fire - dead since the same change that killed the orphan must-fire above.
$outPattern = if ($WholeTreeIsStrict) { '(^|\\)out\\' } else { '(^|\\)grocery\\out\\' }
$inOut= @($all | Where-Object { $_.FullName.Substring($ScanRoot.Length + 1) -match $outPattern })

$exts = '.ps1','.psm1','.js','.yml','.yaml','.vbs','.bat','.cmd'
# THIS FILE MUST NOT BE A SOURCE. $KNOWN quotes every recorded script name; counting it would make every one
# of them "referenced" and the census would report a clean zero forever - a gate that can never arm. (Same reason
# test-auditors.ps1 skips itself when it greps for the logger pattern.)
# NOR MAY A COPY OF THIS FILE BE ONE: $self is a single path, so on 2026-08-03 four worktree copies of this
# census sailed straight past it. The nested-checkout prune above is what holds that line now.
$self = $MyInvocation.MyCommand.Path
$src = @(Get-ChildItem -Path $ScanRoot -Recurse -File -ErrorAction SilentlyContinue |
         Where-Object { $exts -contains $_.Extension.ToLower() -and
                        $_.FullName -ne $self -and
                        $_.FullName -notmatch '\\archive\\' -and
                        $_.FullName -notmatch '\\node_modules\\' -and
                        $_.FullName -notmatch '\\\.git\\' -and
                        -not (Test-InOtherCheckout $_.FullName) })

# A check that examined NOTHING must say so. Every population script is itself a source file, so src can only
# be smaller than pop if the roots are wrong or the tree is not checked out - and "0 orphans" from that is a
# lie, not a pass. Exit 3 is this estate's could-not-evaluate code.
if ($all.Count -eq 0 -or $src.Count -lt $all.Count) {
  Write-Output ("script-census: BLIND - " + $all.Count + " script(s) under " + $Root + " against only " +
                $src.Count + " executable file(s) under " + $ScanRoot + ". Nothing was examined; this proves nothing.")
  exit 3
}

$text = @{}
foreach ($f in $src) {
  try { $t = Get-Content $f.FullName -Raw -ErrorAction Stop } catch { $t = '' }
  $text[$f.FullName] = ($t + '')   # [string]$null is $null, not '' - the + '' is load-bearing on a zero-byte file
}

$uncalled = New-Object System.Collections.ArrayList
foreach ($p in $pop) {
  $hit = $false
  foreach ($k in $text.Keys) {
    if ($k -eq $p.FullName) { continue }                                   # a script naming itself is not a caller
    if ($text[$k].IndexOf($p.Name, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break }
  }
  # REPO-RELATIVE, ALWAYS (2026-09-09, backlog I85 rung 2). The keys used to be relative to $Root,
  # which meant widening the population from grocery\ to the repo made all 52 recorded deliberates
  # stop matching and come back as false orphans. That re-keying WAS the blocker the item named.
  # Keying off $ScanRoot instead makes the register independent of where the population starts, so
  # the same $KNOWN line means the same file whatever $Root is set to.
  if (-not $hit) { [void]$uncalled.Add($p.FullName.Substring($ScanRoot.Length + 1)) }
}

# TWO TIERS, AND THE SPLIT IS THE WHOLE DESIGN (2026-09-09, backlog I85 rung 2).
#
# The item is explicit: widening the population must NOT land 72 findings on day one, because a gate
# red on day one for a backlog nobody is about to clear teaches people to ignore red. But leaving the
# other trees uncensused is what hid 72 unexamined scripts in the first place.
#
# So: grocery\ keeps the HARD rule it has always had - a new unrecorded orphan there is a FAIL - and
# everything outside grocery\ is a RATCHET seeded at today's count, with a high-water mark that may
# only go DOWN. A new orphan outside grocery cannot raise it without failing; recording or wiring one
# lowers it and the ground is held. Neither tier can be satisfied by looking away.
$STRICT_PREFIX = if ($WholeTreeIsStrict) { '' } else { 'grocery' + [IO.Path]::DirectorySeparatorChar }
# THE MARK FOLLOWS -Root, and that is not tidiness. This was Join-Path $PSScriptRoot, so a run scoped to
# ANY other tree wrote the estate's live high-water mark from a population that was not the estate - and
# because a ratchet accepts going DOWN, it did so silently. Hit while reproducing the fixture failure
# above: one command took the mark from 73 to 1, and it was restored from HEAD.
$censusBaselineFile = if ($Root -eq $PSScriptRoot -or $Root -eq (Split-Path $PSScriptRoot -Parent)) {
  Join-Path $PSScriptRoot 'out\script-census-wide-baseline.json'
} else {
  Join-Path $Root 'script-census-wide-baseline.json'
}

$strictUncalled = @($uncalled | Where-Object { $_.StartsWith($STRICT_PREFIX, [StringComparison]::OrdinalIgnoreCase) })
$wideUncalled   = @($uncalled | Where-Object { -not $_.StartsWith($STRICT_PREFIX, [StringComparison]::OrdinalIgnoreCase) })
$wideNew        = @($wideUncalled | Where-Object { -not $KNOWN.Contains($_) })

$new  = @($strictUncalled | Where-Object { -not $KNOWN.Contains($_) })
$gone = @($KNOWN.Keys | Where-Object { $uncalled -notcontains $_ })
$fail = New-Object System.Collections.ArrayList

# THE SCOPE LINE, EVERY RUN (2026-09-08, backlog I85). This report used to open with "273 script(s)
# ... read against 632 executable file(s)" and both totals read as estate-wide. Only one of them is:
# the POPULATION is $Root (which defaults to grocery\), while the SOURCE side is $ScanRoot (the whole
# repo). That asymmetry is why the blind spot was invisible from the output - a reader had no way to
# tell that 72 uncalled scripts under .claude\, meal-prep\, site\, ops\, media\ and sidecar\ had never
# been examined by anything. A rate prints with its denominator; so does a census.
Write-Output ("script-census SCOPE: population = *.ps1 under " + $Root + "  |  source side = executable files under " + $ScanRoot +
              $(if ($Root -eq $ScanRoot) { '' } else { "   <- NOT THE SAME TREE. Scripts outside the population are NOT censused by this run." }))
Write-Output ("script-census: " + $pop.Count + " script(s) + " + $inOut.Count + " under out\, read against " +
              $src.Count + " executable file(s); " + $uncalled.Count + " uncalled, " + $KNOWN.Count + " recorded as deliberate")
# An exclusion nobody can see is its own blind spot: say what was pruned and where, every run.
foreach ($b in $nested) { Write-Output ("  skipped nested checkout " + $b + " - a copy of this repo, not a second set of scripts") }
if ($gone.Count -gt 5) { Write-Output ("  note    " + $gone.Count + " recorded entries are no longer uncalled here - drop their KNOWN lines") }
else { foreach ($g in $gone) { Write-Output ("  note    " + $g + " is called again (or archived) - drop its KNOWN line") } }
foreach ($n in $new)  { [void]$fail.Add("ORPHAN " + $n + " - no executable file in the repo names it") }
if ($inOut.Count -gt $OutBaseline) {
  [void]$fail.Add("out\ grew to " + $inOut.Count + " .ps1 (baseline " + $OutBaseline + ") - a one-off was written into the pipeline's OUTPUT directory")
} elseif ($inOut.Count -lt $OutBaseline) {
  Write-Output ("  note    out\ is down to " + $inOut.Count + " .ps1 - lower OutBaseline to hold the ground")
}

# ---- the wide tier: a ratchet, never a day-one gate ------------------------------------------------
$wideBase = $null
if (Test-Path $censusBaselineFile) {
  # -Encoding UTF8 is not optional: PS 5.1 decodes a BOM-less file with the ANSI codepage, and
  # audit-json-readers.ps1 ratchets exactly this. Caught by that ratchet the same day this was written.
  try { $wideBase = [int]((Get-Content $censusBaselineFile -Raw -Encoding UTF8 | ConvertFrom-Json).uncalled) } catch { $wideBase = $null }
}
Write-Output ("  wide tier: " + $wideUncalled.Count + " uncalled outside " + $STRICT_PREFIX + " (" +
              $wideNew.Count + " not yet recorded in KNOWN)" +
              $(if ($null -eq $wideBase) { '  - NO BASELINE YET, run -WideBaseline once' } else { "  baseline " + $wideBase }))
if ($null -ne $wideBase) {
  if ($wideNew.Count -gt $wideBase) {
    [void]$fail.Add("WIDE RATCHET ROSE: " + $wideNew.Count + " unrecorded orphan(s) outside " + $STRICT_PREFIX +
                    ", over the high-water mark of " + $wideBase + ". A NEW uncensused script appeared. Wire it in, archive it, or record it in KNOWN.")
  } elseif ($wideNew.Count -lt $wideBase) {
    Write-Output ("  note    wide ratchet is below its mark (" + $wideNew.Count + " < " + $wideBase + ") - re-run with -WideBaseline to hold the ground")
  }
}
if ($WideBaseline) {
  if ($null -ne $wideBase -and $wideNew.Count -gt $wideBase) {
    Write-Output ("  REFUSING to raise the wide high-water mark from " + $wideBase + " to " + $wideNew.Count + ". A ratchet may only go DOWN.")
    exit 2
  }
  $od = Split-Path $censusBaselineFile -Parent
  if (-not (Test-Path $od)) { New-Item -ItemType Directory -Force -Path $od | Out-Null }
  @{ uncalled = $wideNew.Count; recorded = (Get-Date -Format 'yyyy-MM-dd')
     note = 'HIGH-WATER MARK for unrecorded orphans OUTSIDE grocery\. May only go DOWN. Backlog I85 rung 2. grocery\ itself is a hard gate, not a ratchet.' } |
    ConvertTo-Json -Depth 3 | Set-Content $censusBaselineFile -Encoding UTF8
  Write-Output ("  wide baseline set to " + $wideNew.Count)
}

if ($fail.Count -eq 0) { Write-Output ("  ok      no unrecorded orphan; out\ holds " + $inOut.Count + " one-off(s), at or under baseline"); exit 0 }
foreach ($m in $fail) { Write-Output ("  FAIL    " + $m) }
Write-Output ("script-census FAIL: " + $fail.Count + " finding(s). Wire it in, move it to archive\one-off\, or record it in KNOWN with the reason it stays uncalled.")
exit 2

