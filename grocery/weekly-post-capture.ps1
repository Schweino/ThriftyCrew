<#
  weekly-post-capture.ps1 - the DETERMINISTIC tail of the weekly browser-stores refresh, wrapped in one
  orchestrator so the Wednesday agent spends its tokens on captures + judgment, not on shepherding a
  dozen script calls (2026-07-26 token-diet item; same conversion pattern as bakers-daily-scan.ps1).

  THREE PHASES, called by the agent at its natural pause points:

    -Phase compare  [-BakersFile x] [-SamsFile x] [-FarewayFile x]
        compare-deals (-MinStores 1 + the capture files) -> audit-coverage-gaps -> audit-sale-fallback
        -> update-history -> verify-prep.
        THEN THE AGENT JUDGES: verify-input entries (step H verdicts -> verify-verdicts-<today>.json),
        coverage-gap regex widenings, multibuy/BOGO extra-deals. Re-run -Phase compare after any fix
        that changes inputs (idempotent).

    -Phase publish
        verify-apply -> verify-apply (MinStores 1 -> verified-history, so the long tail keeps its history)
        -> update-history (banks the VERIFIED board, never the raw comparison) -> sanity-check (flags
        REPORTED) -> guards.ps1 (HARD gate: exit 2 = HELD - the SAME gate check-ad-cycles runs daily) ->
        publish-deals-page (self-gates on coverage; HELD is a real stop) -> resolve-worklist.
        THEN THE AGENT RESOLVES LINKS: browser re-resolve of url-worklist chips (step K2).

    -Phase links
        merge-product-urls -> resolve-worklist (re-flag) -> stamp-board-pu -> publish-deals-page ->
        audit-links + audit-name-drift (reported) -> push-data.

  Every step is stderr-tolerant but exit-code-strict (RunChild); failures print FAIL and exit 1 so the
  agent can react. Log: out\logs\weekly-post-capture-<yyyy-MM>.log
#>
param(
  [Parameter(Mandatory)][ValidateSet('compare','publish','links')][string]$Phase,
  [string]$BakersFile = '', [string]$SamsFile = '', [string]$FarewayFile = ''
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$logDir = Join-Path $root 'out\logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir ('weekly-post-capture-' + (Get-Date -Format 'yyyy-MM') + '.log')
# a locked log file must never kill the capture - see the note in check-ad-cycles.ps1 (2026-07-28)
function Log([string]$m){
  $line=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'  ['+$Phase+'] '+$m
  for ($i = 0; $i -lt 5; $i++) { try { Add-Content -Path $log -Value $line -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 120 } }
  Write-Host $line
}
function RunChild([string]$file,[object[]]$childArgs,[int]$keep=2,[string]$tag='step',[switch]$NonFatal){
  $prev=$ErrorActionPreference; $ErrorActionPreference='Continue'
  try {
    $out = & powershell -ExecutionPolicy Bypass -File $file @childArgs 2>&1 | ForEach-Object { [string]$_ }
    $ec = $LASTEXITCODE
    @($out | Select-Object -Last $keep) | ForEach-Object { Log ($tag + ': ' + $_) }
    if($ec -ne 0 -and -not $NonFatal){ throw ("{0} exited {1}" -f (Split-Path $file -Leaf), $ec) }
    return [int]$ec
  } finally { $ErrorActionPreference = $prev }
}

try {
  # ---- HOLD THE WEEKLY LOCK FOR THE WHOLE RUN (2026-07-30). On 2026-07-29 the 8:30 daily job started 29
  # minutes after this script's 08:01:34 links phase and 16 minutes before its 08:46:24 publish phase - i.e.
  # squarely inside the run, in a judgment gap - and spent 46m42s recomputing and republishing the same board.
  # So EVERY phase takes the lock, and NOTHING here ever hands it back. That asymmetry is deliberate and
  # measured: the same run executed three SUCCESSFUL links phases (07:55:21, 07:58:07, 08:01:34), each ending
  # in push-data, and then published again at 08:46:24. Releasing after "the last step" would therefore have
  # freed grocery\out 28.5 minutes before the daily fired - the exact hole this lock exists to close. The
  # agent iterates; no phase reliably means done. The lock expires on its own instead: weekly-run-lock.ps1
  # stamps an expiry into the file (4h, vs a measured 187.5-min worst-case in-run pause), and the daily sweeps
  # an expired one after reporting it. -NonFatal on purpose - a lock we cannot write must never stop the
  # week's prices.
  $null = RunChild (Join-Path $root 'weekly-run-lock.ps1') @('-Acquire', '-Phase', $Phase) 1 'lock' -NonFatal
  switch ($Phase) {
    'compare' {
      $cmpArgs = @('-MinStores','1')
      if($BakersFile){ $cmpArgs += @('-BakersFile',$BakersFile) }
      if($SamsFile){ $cmpArgs += @('-SamsFile',$SamsFile) }
      if($FarewayFile){ $cmpArgs += @('-FarewayFile',$FarewayFile) }
      $null = RunChild (Join-Path $root 'compare-deals.ps1') $cmpArgs 3 'compare'
      $null = RunChild (Join-Path $root 'audit-coverage-gaps.ps1') @() 3 'coverage' -NonFatal
      $null = RunChild (Join-Path $root 'audit-sale-fallback.ps1') @() 3 'fallback' -NonFatal
      # NOTE: update-history deliberately does NOT run here. It used to, and that banked the week's "cheapest"
      # from the board BEFORE the semantic verify - so every wrong-product winner the verify pass exists to
      # catch set a RECORD LOW on its way out (strawberries $0.0833 from an applesauce, honey $0.1244 from hot
      # dog buns). It now runs in -Phase publish, after verify-apply. See grocery-engine-guards.
      $null = RunChild (Join-Path $root 'verify-prep.ps1') @() 2 'verify-prep'
      Log 'PHASE compare DONE. Agent: judge verify-input entries (write verify-verdicts), review coverage/fallback/multibuy flags, then -Phase publish.'
    }
    'publish' {
      # AUDIT THE BOARD THAT ACTUALLY SHIPS (2026-07-30). Both of these ran in -Phase compare ONLY, and the
      # comparison this phase consumes is routinely NOT the one -Phase compare produced: the daily job and hand
      # re-runs rewrite comparison-<week>.json between the two calls. On 2026-07-29 audit-coverage-gaps wrote
      # gap_count=0 at 09:10, out\regular\aldi-regular-2026-07-29.json was rebuilt at 12:24, the comparison was
      # rewritten at 12:29, and this phase shipped it at 12:58 - by then Aldi had dropped out of the bread row
      # and the published row crowned Walmart at 1.48/each with Aldi's loaf at 1.45 in the same day's capture.
      # They STAY in -Phase compare too: that is where the agent judges include-regex widenings, and these
      # flags are the input to that judgement. Measured cost on today's data: 8.5s + 2.0s per publish attempt.
      # They are pointed at the COMPARISON, never verified-<week>.json, on purpose. The verified board has had
      # human verdicts and the MinStores-2 display filter applied, and both are DELIBERATE removals: measured
      # on 2026-07-29, 20 gaps against comparison-2026-07-29.json but 44 against verified-2026-07-29.json, and
      # all 24 extra are policy (19 on commodities MinStores 2 drops whole, 5 on verdict-dropped cells).
      # Coverage is a question about the ENGINE's matching, so it is asked of the engine's own output.
      $cmpPub = Get-ChildItem (Join-Path $root 'out\comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
      if (-not $cmpPub) { throw 'no out\comparison-*.json exists - there is no board to verify, gate or publish' }
      $cgRc = RunChild (Join-Path $root 'audit-coverage-gaps.ps1') @('-CompareFile', $cmpPub.FullName) 1 'coverage' -NonFatal
      $cgJ = try { Get-Content (Join-Path $root 'out\coverage-gaps.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
      if ($cgRc -eq 3) { Log ('PRE-PUBLISH coverage: BLIND - zero raw products parsed for EVERY store, so ' + $cmpPub.Name + ' is UNCHECKED for silently dropped stores. A no-gaps verdict on it would be an empty claim.') }
      elseif (-not $cgJ) { Log ('PRE-PUBLISH coverage: audit-coverage-gaps exited ' + $cgRc + ' and out\coverage-gaps.json is missing or unreadable - ' + $cmpPub.Name + ' was NOT checked.') }
      elseif ([int]$cgJ.gap_count -gt 0) { Log ('PRE-PUBLISH coverage: ' + [int]$cgJ.gap_count + ' store(s) carry an item but are off ' + $cmpPub.Name + ' - ' + ((@($cgJ.gaps | ForEach-Object { [string]$_.commodity + ' @ ' + [string]$_.store }) | Select-Object -First 12) -join '; ') + ' (full list out\coverage-gaps.json). ADVISORY - this is the board about to ship.') }
      else { Log ('PRE-PUBLISH coverage: none on ' + $cmpPub.Name) }
      if ($cgJ -and @($cgJ.stores_not_scanned | Where-Object { $_ }).Count) { Log ('PRE-PUBLISH coverage: NOT checked for ' + ((@($cgJ.stores_not_scanned | Where-Object { $_ })) -join ', ') + ' - zero raw products were parsed for them, so their absence from a commodity proves nothing.') }
      $sfRc = RunChild (Join-Path $root 'audit-sale-fallback.ps1') @('-CompareFile', $cmpPub.FullName) 1 'fallback' -NonFatal
      $sfJ = try { Get-Content (Join-Path $root 'out\sale-fallback-gaps.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
      if (-not $sfJ) { Log ('PRE-PUBLISH sale-fallback: audit-sale-fallback exited ' + $sfRc + ' and out\sale-fallback-gaps.json is missing or unreadable - ' + $cmpPub.Name + ' was NOT checked.') }
      elseif ([int]$sfJ.gap_count -gt 0) { Log ('PRE-PUBLISH sale-fallback: ' + [int]$sfJ.gap_count + ' on-sale cell(s) on ' + $cmpPub.Name + ' have no everyday item to revert to - ' + ((@($sfJ.gaps | ForEach-Object { [string]$_.commodity + ' @ ' + [string]$_.store }) | Select-Object -First 12) -join '; ') + ' (full list out\sale-fallback-gaps.json). ADVISORY.') }
      else { Log ('PRE-PUBLISH sale-fallback: none on ' + $cmpPub.Name) }
      $null = RunChild (Join-Path $root 'verify-apply.ps1') @() 2 'verify-apply'
      # Price history banks the VERIFIED board, never the raw comparison. Built at MinStores 1 into its own
      # file so the ~24 single-store long-tail commodities keep their history even though MinStores 2 keeps
      # them off the published page - that is the only reason history used to run against the raw board.
      $histFile = 'verified-history.json'
      $null = RunChild (Join-Path $root 'verify-apply.ps1') @('-MinStores','1','-OutFile',$histFile) 2 'verify-history'
      $null = RunChild (Join-Path $root 'update-history.ps1') @('-CompareFile',(Join-Path $root ('out\' + $histFile))) 1 'history'
      # A DROP verdict lands AFTER the weeks it poisoned. verify-apply stops the product publishing from now on,
      # but price-history keeps every week it already won, and compaction preserves each week's minimum forever -
      # so the wrong number owns "lowest we have tracked" permanently. purge-verdict-lows deletes exactly the
      # entries a verdict NAMES. Evidence, not a ratio: the pork-loin filet crowning bacon was 1.02x under the
      # next week and purge-bad-lows' >=2x test can never see it. Idempotent (a second run reports 0 changes).
      # -NonFatal because exit 3 here means "a record_low refusal blocks a recompute, a human decides", not a
      # failed step; it must not hold the publish.
      $null = RunChild (Join-Path $root 'purge-verdict-lows.ps1') @('-Apply') 3 'purge-verdict-lows' -NonFatal
            $null = RunChild (Join-Path $root 'sanity-check.ps1') @() 4 'sanity' -NonFatal
      # ---- ARRIVALS DESK. The weekly run is the day the most NEW products enter - the browser stores are all
      # re-captured at once, so arrivals jump from ~30 on a quiet day to 521 (2026-07-29). That is exactly the
      # day the most wrong products enter, and exactly the day a fixed-size review misses them, so the docket
      # must be produced here too and not only on the daily path. -NonFatal: this is a REVIEW QUEUE at 5-15%
      # measured precision and it must never hold the weekly publish; exit 3 means "could not evaluate the
      # delta", which is a note for the agent, not a failed step. The ranked docket is out\arrivals-docket.json;
      # read the CROWN block first, a wrong product is 4x more likely to hold a crown.
      $null = RunChild (Join-Path $root 'build-arrivals-docket.ps1') @() 3 'arrivals' -NonFatal
      $g = Join-Path $root ('out\guards-' + (Get-Date -Format 'yyyy-MM-dd') + '.json')
      if(Test-Path $g){ Log ('sanity flags file present: ' + $g + ' - REVIEW before trusting the board.') }
      # THE SAME GATE THE DAILY JOB USES (added 2026-07-29). guards.ps1 was wired into check-ad-cycles only, so
      # the WEEKLY path could publish a board the daily hard gate would refuse - and did. On 2026-07-29 this
      # run published cleanly, then guards.ps1 on the identical data reported four hard fails: three Aldi
      # multipack rows recording ONE unit as the whole pack, and a Sam's "brown rice" that was a Seeds of
      # Change quinoa microwave pouch at $3.76/lb. Later passes caught 4-gallon bin liners winning the
      # 13-GALLON kitchen-bag row and liquid cold brew crowning ground coffee. Two paths to publish must not
      # have two definitions of "safe".
      # REFRESH THE GATE'S OWN INPUTS BEFORE THE GATE READS THEM (2026-07-29, found the hard way).
      # guards.ps1:188 runs audit-tile-integrity, whose WRONG-PRODUCT verdicts come from out\name-drift.json -
      # and until now the only thing that regenerated that file was publish-deals-page.ps1:69, which runs AFTER
      # guards. So the gate graded the new board against a PREVIOUS run's drift flags, and the publish then
      # refreshed them. Tonight that shipped six Walmart links pointing at the wrong product (butter, chickpeas,
      # egg-whites by name-drift; storage-bags, laundry-pods, soda by count-mismatch): the 2,726 fresh Walmart
      # rows changed which product wins those cells, guards saw stale flags and said OK, and the defect only
      # surfaced when guards was re-run by hand afterwards. A gate that reads an input its own subject rebuilds
      # is one publish behind by construction.
      $null = RunChild (Join-Path $root 'audit-links.ps1') @() 3 'pre-gate-links' -NonFatal
      $null = RunChild (Join-Path $root 'audit-name-drift.ps1') @() 3 'pre-gate-drift' -NonFatal
      $gc = RunChild (Join-Path $root 'guards.ps1') @() 4 'guards' -NonFatal
      if($gc -eq 2){ Log 'publish HELD by guards.ps1 - a HARD invariant is violated (see the guards lines above). Fix the data, then re-run -Phase publish.'; exit 2 }
      if($gc -ne 0){ throw "guards.ps1 exited $gc" }
      $rc = RunChild (Join-Path $root 'publish-deals-page.ps1') @() 3 'publish' -NonFatal
      if($rc -eq 2){ Log 'publish HELD by coverage gate - fix the thin store, then re-run -Phase publish.'; exit 2 }
      if($rc -ne 0){ throw "publish-deals-page exited $rc" }
      $null = RunChild (Join-Path $root 'resolve-worklist.ps1') @() 2 'worklist'
      Log 'PHASE publish DONE. Agent: browser-resolve the url-worklist chips (per-store method memories), then -Phase links.'
    }
    'links' {
      $null = RunChild (Join-Path $root 'merge-product-urls.ps1') @() 2 'merge'
      $null = RunChild (Join-Path $root 'resolve-worklist.ps1') @() 2 'reflag'
      $null = RunChild (Join-Path $root 'stamp-board-pu.ps1') @() 2 'stamp'
      # THIS PHASE PUBLISHES THE BOARD AND IT IS THE LAST PUBLISH OF THE WEEKLY RUN, so it needs the SAME
      # repair-then-gate chain the daily job has run since check-ad-cycles.ps1:671-693. It had none: it merged
      # links, re-stamped pins and republished, with no prune and no guards. A link merged during the browser
      # resolution step that is off by a factor, or that moves a pin's source so the pin is no longer derivable,
      # went straight to the live board - and then sat there until the next morning's daily job hard-failed and
      # refused to publish, leaving the ungated weekly board live overnight.
      # Order matters and mirrors the daily chain exactly:
      #   prune   - drop links that drifted by a FACTOR (0.32 = everything guards would hard-fail on, nothing
      #             more, so the repair can never deadlock the publish on a normal price nudge)
      #   sync    - immediately re-create any browser link the prune just dropped whose row still carries the
      #             product identity, so a pruned link is healed in the same pass instead of leaving a gap
      #   pins    - links just changed, so pins derived from them must be re-minted BEFORE guards re-checks
      #   audits  - refresh name-drift/links, which are the gate's OWN inputs (see the note in -Phase publish)
      #   guards  - and only publish if it passes
      $null = RunChild (Join-Path $root 'prune-bad-links.ps1') @('-Tol','0.32') 3 'prune' -NonFatal
      $null = RunChild (Join-Path $root 'sync-browser-links.ps1') @() 3 'sync-links' -NonFatal
      $null = RunChild (Join-Path $root 'generate-board-overrides.ps1') @() 3 'pins' -NonFatal
      $null = RunChild (Join-Path $root 'audit-links.ps1') @() 3 'audit-links' -NonFatal
      $null = RunChild (Join-Path $root 'audit-name-drift.ps1') @() 3 'name-drift' -NonFatal
      $lg = RunChild (Join-Path $root 'guards.ps1') @() 4 'guards' -NonFatal
      if($lg -eq 2){ Log 'links HELD by guards.ps1 - the link merge broke a hard invariant. The live board is UNCHANGED (last good). Fix the links, then re-run -Phase links.'; exit 2 }
      if($lg -ne 0){ throw "guards.ps1 exited $lg" }
      $rc = RunChild (Join-Path $root 'publish-deals-page.ps1') @() 3 'republish' -NonFatal
      if($rc -eq 2){ Log 'republish HELD by coverage gate (unusual at this stage) - investigate.'; exit 2 }
      if($rc -ne 0){ throw "publish-deals-page exited $rc" }
      # POST-PUBLISH VERIFICATION. publish-deals-page regenerates name-drift.json as it builds, so this is the
      # first moment the shipped board can be graded against fresh drift flags. Advisory, not a gate: the board
      # is already live, and the honest move is to say so loudly rather than pretend the pre-check covered it.
      $tiPost = RunChild (Join-Path $root 'audit-tile-integrity.ps1') @() 3 'post-publish-tiles' -NonFatal
      if($tiPost -eq 3){ Log 'POST-PUBLISH: audit-tile-integrity was BLIND on the live board (zero links graded) - product-urls.json is empty or unreadable, the live links are UNVERIFIED. prune-bad-links will NOT fix this; check product-urls.json first.' }
      elseif($tiPost -ne 0){ Log 'POST-PUBLISH: audit-tile-integrity FAILED on the board that just went live - run prune-bad-links -Tol 0.32 and re-run -Phase links NOW.' }
      $null = RunChild (Join-Path $root 'push-data.ps1') @() 1 'push'
      Log 'PHASE links DONE. Agent: report audit-links/name-drift residue; re-resolve any form-flips and re-run -Phase links if needed.'
    }
  }
  exit 0
} catch {
  Log ('FAIL: ' + $_.Exception.Message)
  exit 1
}