# edge-decision-lib.ps1 - the pure edge read-after-write and post decisions capture-run.ps1 runs on.
# Moved out of grocery/capture-run.ps1 verbatim on 2026-09-30 (queue 2026-09-30-16027b send-back) so that file stays
# under its ops/audit-file-size-budget.ps1 mark. Dot-sourced by capture-run.ps1 at startup (so it is on
# $script:TcCheckoutSyncStartupFiles in lib/checkout-sync.ps1) and lifted between its markers by
# grocery/test-capture-builders.ps1, which reads THIS shipped file, never a copy. Functions only: no param() block,
# no top-level statements, nothing runs on load.

# >>> EDGE-DECISION >>>
# THE DECISION, LIFTED OUT SO A FIXTURE CAN REACH IT (2026-09-03, queue 2026-09-03-58057b).
# THE RULE THIS FILE NOW RUNS ON: any read-after-write in this chain compares against GIT, never against
# the working tree, and gates on $shipServed, never on $pushed.
# What went wrong on 2026-09-03: the block below gated on ($runDownstream -and $pushed) and read its own
# side of the comparison from the WORKING TREE. Both halves are wrong for a held-back board. $pushed is a
# whole-run flag - line 816 sets it true for "nothing to ship is not a failed ship" - so it is true on a
# run where public\** was never in the commit at all; and the recipe lane rewrites public\smp-feed.json
# BEFORE guards run, so on a guards-blocked day that file is dirty on purpose and comparing the edge
# against it manufactures a mismatch. The alert then asserted a conclusion it never checked ("The push
# succeeded, so this is a Cloudflare deploy that has not landed") and accused a third party, on exactly
# the day the operator is already busy with a real hard fail. The edge was in fact serving the newest
# PUSHED feed correctly. The correct predicate was already eight lines above, in the served-dirty block.
function Test-EdgeServesPushed {
  <# .DESCRIPTION Pure. ok | stale | skipped | blind. No network, no git, no clock - so a fixture can drive
     every arm without a repo. 'skipped' is the 2026-09-03 founding bug: the chain deliberately did not ship
     the served files, so there is nothing to verify and NOTHING TO ALERT ABOUT. 'blind' is could-not-run,
     which is not a failure either. #>
  param(
    [bool]$ShipServed,
    [string]$CommittedGenerated,
    [string]$LiveGenerated
  )
  if (-not $ShipServed) { return 'skipped' }
  if ([string]::IsNullOrWhiteSpace($CommittedGenerated)) { return 'blind' }
  if ([string]::IsNullOrWhiteSpace($LiveGenerated))      { return 'stale' }
  if ([string]$LiveGenerated -eq [string]$CommittedGenerated) { return 'ok' }
  return 'stale'
}
# THE BYTE COMPARISON (2026-09-04, queue 2026-09-04-4ec26c). The board.json read-after-write compared a
# CONSOLE-CODE-PAGE decode of the git blob (`git show | Out-String`) against a UTF-8 decode of the live
# response, so it compared two different decodings of identical bytes and could never pass on a board
# containing a single non-ASCII character. Measured the morning it fired: the edge and HEAD were byte-for-
# byte identical (SHA256 C24A9BF3..., 2,961,318 bytes on both sides), and the alert's own two numbers were
# that one file in two units - 2,961,318 bytes, 2,959,184 UTF-8 characters, and the board carries exactly
# 2,134 characters above U+007F.
# Pure, and it takes HASHES rather than the payloads: a byte-by-byte loop over 2.9 MB in PowerShell costs
# seconds, and a hash is the same answer. An unreadable side is BLIND, never 'ok' - two empty hashes must
# not compare equal and read as agreement.
function Test-EdgeServesPushedBytes {
  <# .DESCRIPTION Pure. ok | stale | blind. Hex SHA256 of the committed blob vs the live response. #>
  param([string]$CommittedHash, [string]$LiveHash)
  if ([string]::IsNullOrWhiteSpace($CommittedHash)) { return 'blind' }
  if ([string]::IsNullOrWhiteSpace($LiveHash))      { return 'blind' }
  if ($CommittedHash -eq $LiveHash) { return 'ok' }
  return 'stale'
}
function Test-PointerShippedWithoutObject {
  <#
    THE POINTER SHIPPED AND THE OBJECT DID NOT (2026-09-22, queue 2026-09-22-972de2).
    .claude\rules\ops-and-gates.md: "Write the POINTED-TO object before the object that points to it.
    Every interruption then leaves an object nothing refers to yet, which is a LEAK, and never a reference
    to an object that is not there, which is CORRUPTION." This chain does it the other way round. The Ghost
    post is upserted inside check-ad-cycles' ship path and carries board.json?v=<hash of the board it just
    built>; public\board.json reaches readers only through the commit BELOW, which can fail on its own.
    .claude\rules\site-and-publish.md already says the right order in words and nothing enforced it.

    WHAT IT COST. On 2026-09-22 the ship path published the post at 08:17 asking for board.json?v=56fb50a601
    and the commit was refused eighteen minutes later. From then until a human looked, the live post said
    "week of 2026-09-22" while feed.thriftycrew.com served origin/main's 2026-09-21 board (blob e266e0d45),
    and 583 recipe pages priced off a 2026-09-21 smp-feed. The branch below printed
    "edge check skipped: ... Readers keep the last good board." Readers did NOT: they kept the last good
    board.json underneath a post advertising a different one, and the check had never tested the claim.

    WHY THE OLD SILENCE WAS RIGHT ONCE AND WRONG HERE. The skip was scoped on 2026-09-03 to the
    guards-blocked day, where the chain deliberately ships nothing AND publishes no post, so nothing points
    at anything missing. On 2026-09-09 the refused-commit case was folded into the same branch. That was
    correct for the served-dirty ALERT one block up, which would have prescribed an inert repair, and wrong
    for the edge check, which is the only thing still asking a question that matters when a commit is
    refused. So this decides on the POINTER, not on the reason the commit failed, and covers every reason:
    a refused hook, a non-fast-forward rejection, a push lock, a network failure.

    Measured over the 28 daily logs on disk (2026-08-24 to 2026-09-22): the branch below was reached on 3
    days and all 3 had shipServed=True, so all 3 were reassurances about a state nobody had read.
  #>
  param([bool]$ShipServed, [bool]$ObjectLanded, [bool]$ObjectDirty)
  if (-not $ShipServed) { return 'nothing-shipped' }
  if ($ObjectLanded)    { return 'ok' }
  if ($ObjectDirty)     { return 'pointer-without-object' }
  return 'ok'
}
function Get-DeferredPostDecision {
  <#
    THE POST SHIPS AFTER THE DATA IT POINTS AT IS LIVE (2026-09-22, queue 2026-09-22-81d955). The PREVENTIVE half of
    Test-PointerShippedWithoutObject above: check-ad-cycles -DeferPost no longer upserts the post, and this decides whether
    capture-run publishes it now. 'publish' only when the served files landed (committed AND pushed) and the edge serves
    the committed board.json AND smp-feed.json byte for byte; every other state is 'hold:<why>', which leaves readers on
    yesterday's post over yesterday's board (a LEAK the next run repairs), never today's post over yesterday's board
    (CORRUPTION, which is what 2026-09-22 shipped for five hours). A could-not-look on either edge read is a hold.
  #>
  param([bool]$Deferred, [bool]$ObjectLanded, [string]$EdgeBoard, [string]$EdgeFeed)
  if (-not $Deferred) { return 'none' }
  if (-not $ObjectLanded) { return 'hold:the served files did not land (commit refused or push failed), so the post would point at a board readers cannot get' }
  if ($EdgeBoard -ne 'ok') { return ('hold:the edge does not serve the committed board.json (' + $(if ($EdgeBoard) { $EdgeBoard } else { 'not read' }) + ')') }
  if ($EdgeFeed -ne 'ok') { return ('hold:the edge does not serve the committed smp-feed.json (' + $(if ($EdgeFeed) { $EdgeFeed } else { 'not read' }) + ')') }
  return 'publish'
}
function Get-HeldPostDecision {
  <#
    A HELD POST REPUBLISHES ITSELF ONCE ITS DATA IS LIVE, WHOEVER LANDED IT (2026-09-26, queue 2026-09-26-518fff, the
    leftover of 2026-09-23-80f302). Get-DeferredPostDecision above only asks "did THIS run push?", and it only honours a
    deferral dated today. On 2026-09-24 and again on 2026-09-25 the run held its post because its own push did not land;
    each commit landed LATER on somebody else's push, nothing publishes a post for a push it did not make, and the deferral
    expired at midnight, so the live post named a board the edge no longer served. This decides a deferral CARRIED from an
    earlier day on what is TRUE NOW, not on what this run did:
      publish  only when the board the deferral recorded (board_sha256, SHA-256 of public\board.json as written) is the
               board on origin/main, is the board in this checkout, AND is the board feed.thriftycrew.com serves. Every
               comparison is ordinal on the hex; a blank on any side is a could-not-look, which is a hold, never a match.
      clear    the deferral's signature is already the published one (another road published this board), so nothing
               is owed and the record goes.
      hold     anything else, including a record written before board_sha256 existed (it cannot prove which board it
               names). The record stays, so the next run asks again: it never expires by the clock.
      none     nothing pending, or the deferral is today's, which Get-DeferredPostDecision owns.
    publish-deals-page re-checks the edge against the board it names before its first Ghost write, so this can only
    make a publish LESS likely than that gate, never more.
  #>
  param([bool]$Pending, [string]$DocDate, [string]$Today, [string]$DocBoardSha, [string]$DocSig, [string]$PublishedSig,
        [string]$OriginBoardSha, [string]$TreeBoardSha, [string]$EdgeBoardSha)
  if (-not $Pending) { return 'none' }
  if ([string]::Equals([string]$DocDate, [string]$Today, [StringComparison]::Ordinal)) { return 'none' }
  if ($DocSig -and $PublishedSig -and [string]::Equals($DocSig.Trim(), $PublishedSig.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
    return 'clear:published-board.sig already records this deferral''s board, so another road published it'
  }
  if (-not $DocBoardSha) { return 'hold:the deferral carries no board_sha256 (written before 2026-09-26), so it cannot prove which board the post would name' }
  $want = $DocBoardSha.Trim().ToUpperInvariant()
  if (-not $OriginBoardSha) { return 'hold:could not read public/board.json on origin/main, so the landing is unproven' }
  if (-not [string]::Equals($OriginBoardSha.Trim().ToUpperInvariant(), $want, [StringComparison]::Ordinal)) { return 'hold:origin/main does not carry the board this deferral names (its push has not landed, or a newer board replaced it)' }
  if (-not $TreeBoardSha) { return 'hold:could not read public\board.json in this checkout' }
  if (-not [string]::Equals($TreeBoardSha.Trim().ToUpperInvariant(), $want, [StringComparison]::Ordinal)) { return 'hold:this checkout holds a different public\board.json than the deferral names, so a rebuild here would name another board' }
  if (-not $EdgeBoardSha) { return 'hold:could not read board.json from feed.thriftycrew.com' }
  if (-not [string]::Equals($EdgeBoardSha.Trim().ToUpperInvariant(), $want, [StringComparison]::Ordinal)) { return 'hold:feed.thriftycrew.com does not serve the board this deferral names yet' }
  return 'publish'
}
# THE POLL, LIFTED OUT AND MEASURED (2026-09-30, queue 2026-09-30-16027b, a RETURN of 2026-09-03-58057b).
# The inline loop polled 10 x 30 s and paged at 5 minutes, a bar nobody had measured: its verdict and elapsed
# time went to a discarded stdout. On 2026-09-30 the push landed at 09:03:36, the page fired at 09:08:42, and the
# edge served HEAD byte-for-byte by 09:53:50 without anyone acting: a slow Workers Build and a failed one made the
# same page. So the poll runs 10 x 30 s then 15 x 60 s (20 minutes, the first plausible value, 4x the old bar and
# inside the observed 50-minute upper bound, not a sweep survivor), a healthy day still stops at the first match,
# and the caller appends every result to out\edge-deploy-latency.log so the bar can be set from a distribution.
# Seams: -Fetch returns the live feed as an object with .generated (or $null / throws), -Sleep takes seconds.
# Sleep comes FIRST on every attempt, as the inline loop did: poll 1 is at 30 s, poll 25 at 1200 s.
function Wait-EdgeServesPushed {
  param(
    [string]$CommittedGenerated,
    [scriptblock]$Fetch,
    [scriptblock]$Sleep = { param($s) Start-Sleep -Seconds $s },
    [int[]]$ScheduleSeconds = (@(30) * 10 + @(60) * 15)
  )
  if ([string]::IsNullOrWhiteSpace($CommittedGenerated)) {
    return [pscustomobject]@{ verdict = 'blind'; attempts = 0; elapsed_s = 0; live_generated = ''; live = $null }
  }
  $elapsed = 0; $attempts = 0; $last = $null
  foreach ($sec in $ScheduleSeconds) {
    & $Sleep $sec
    $elapsed += $sec; $attempts++
    $r = $null
    try { $r = & $Fetch } catch { $r = $null }
    if ($null -ne $r) { $last = $r }
    if ($null -ne $r -and [string]$r.generated -eq $CommittedGenerated) {
      return [pscustomobject]@{ verdict = 'ok'; attempts = $attempts; elapsed_s = $elapsed; live_generated = [string]$r.generated; live = $r }
    }
  }
  $lg = if ($null -ne $last) { [string]$last.generated } else { '' }
  return [pscustomobject]@{ verdict = 'stale'; attempts = $attempts; elapsed_s = $elapsed; live_generated = $lg; live = $last }
}
# <<< EDGE-DECISION <<<
