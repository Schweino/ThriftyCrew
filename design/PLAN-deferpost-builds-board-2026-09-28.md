# PLAN: the deferred post path must build the board it ships (2026-09-28)

Status: under way. Written by the 2026-09-28 browser-refresh session at Brad's "Fix ALL open items now".

## Knowledge consulted

- rules:ops-and-gates.md og-51: "Write the POINTED-TO object before the object that points to it" - the rule
  0da71cba5 applied; the defect is that the pointed-to object (board.json) is never rebuilt before it ships.
- rules:site-and-publish.md: "public/board.json carries structured __rows, and committing that file IS the
  feed deploy. It ships BEFORE the post." and "build-deals-page clobbers public/ artifacts".
- memory:C--Codex-ThriftyCrew/an-agreeing-number-escapes-scrutiny (via rules:graph.md): the first
  work-vs-HEAD comparison in this investigation agreed on 646 of 646 because of a case-insensitive variable
  collision ($h / $H); the re-check against a known-different board found 562 differences.

## What is broken

Since 0da71cba5 (2026-09-22, queue 2026-09-22-81d955) capture-run calls
`check-ad-cycles.ps1 -NoPull -NoCommit -DeferPost`. Under `-DeferPost` the branch at
check-ad-cycles.ps1 ~1638 does NOT run `publish-deals-page.ps1`, and `publish-deals-page` is the only
thing that runs `build-deals-page.ps1`, the only writer of `public\board.json`. The branch then hashes
whatever `public\board.json` is already on disk into `out\post-deferred.json` (`board_sha256`).

So on every daily run since 2026-09-22:
1. capture-run commits and pushes `public\board.json` as it was: yesterday's board, or older.
2. It verifies the edge serves that committed (stale) board byte for byte, and it does.
3. It then runs `publish-deals-page`, which rebuilds `public\board.json` from today's comparison, gets a new
   `?v=` hash, finds the edge still serving the old one, and refuses (rc 2): "the post names
   board.json?v=<new> but feed.thriftycrew.com serves v=<old>".

Measured 2026-09-28: comparison-2026-09-28.json moved the cheapest price on 24 of 577 commodities (bacon
Fareway $2.99 -> $1.596; broccoli Aldi $2.09 -> Hy-Vee $1.9969). The served board still carried bacon at
$3.95. The 09:20 rebuild in the main checkout matched comparison-2026-09-28 on 577 of 577 best prices and
was never committed. Daily post outcome by log, 09-22..09-28: 09-23 and 09-28 exactly this (rc 2 after
the data went live); 09-24, 09-25, 09-27 failed earlier at the push; 09-22 and 09-26 no post line. The only
boards readers received after 09-22 were hand republishes by the triage lane (0b1ef1c4b, 94d3e7970 on 09-26).

The ship summary line also misreports this path: `$pubAttempted` is false under `-DeferPost`, so the log
says "no price change since the last publish" every day (check-ad-cycles.ps1 ~1923, the else branch).

## Fix

W1. Under `-DeferPost`, BUILD the served board before it is hashed and handed to the caller: run the build
    half of the publish (build-deals-page, and whatever else publish-deals-page builds into `public\`) with
    no Ghost call, then compute `board_sha256` from the fresh file. The Ghost upsert stays deferred.
W2. The later `publish-deals-page` run in capture-run must name the SAME board it finds at the edge: either
    it does not rebuild when `post-deferred.json` names a board_sha256 that matches the file on disk, or the
    build is byte-deterministic for one comparison. Prove which with two builds over one comparison.
W3. The ship summary under `-DeferPost` says what happened: "board rebuilt, post deferred to the caller",
    never "no price change".
W4. Fixture: a MUST FIRE where a changed comparison under -DeferPost leaves public\board.json unchanged
    (today's defect), and a CLEAN TWIN where the built board's hash is the one post-deferred.json records.

## Today's remediation (done by hand, 2026-09-28)

The guarded 09:20 build (guards 08:19 exit 4 QUARANTINED, 1 cell withheld: celery / Hy-Vee, which the built
board shows as "No price yet") is landed as public\board.json and public\price-history.json through
ops\push-main.ps1, the same road the triage lane used on 2026-09-26. The held post then publishes by the
existing held-post path once the edge serves that board.
