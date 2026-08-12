# Grocery Platform v3 Implementation Contract

V3 supersedes the local v2 contract. It keeps the immutable release, honest batch, integer-money, provenance,
and guard-blindness design and adds funnel telemetry, configuration single-sourcing, Ghost reconciliation,
shelf taxonomy, durable alert triage, independent accuracy sampling, the `tc` CLI, and an explicit calendar.

## Authority

Git owns code, migrations, fixtures, recipes, and the authored files in `config/`. The generator emits the
legacy `grocery/*.json` compatibility files and the bridge deploys the same version to D1. D1 owns operational
state, R2 owns private evidence and large immutable payloads, Analytics Engine owns non-PII funnel events, and
Ghost owns content, entitlements, billing, email, and live paywall truth. Only the Worker owns general D1/R2
authority. A source-scoped capture identity may upload one checksum-bound object through a Worker-issued URL;
the Worker validates and finalizes it before the object becomes evidence.

## Non-negotiable invariants

1. Every public grocery, recipe, feed, Top 5, and rotation response references one published `release_id`.
2. Draft and rejected releases never appear publicly.
3. Partial capture coverage remains explicit at batch and term/page level.
4. Observations are append-only; capture and ingestion times remain distinct.
5. Every displayed price resolves to a product, store location, source, batch, and evidence record.
6. Currency is integer minor units with explicit purchase and normalized bases.
7. Hard guards persist eligible and examined counts; an eligible zero-examination pass is forbidden.
8. Required unpriced recipe ingredients make a recipe incomplete and exclude it from ranked surfaces.
9. The engine selects promoted batch IDs before computation and reads only that immutable snapshot.
10. A public mutation needs authentication, authorization, idempotency/replay protection, and audit identity.
11. Failed, missed, timed-out, and never-started runs remain distinguishable.
12. Authored configuration is edited once; legacy files are generated, never hand-edited.
13. Store shelf taxonomy is captured where available; missing taxonomy cannot authorize an aisle flip.
14. Ghost paywall reconciliation is explicit and verified; client badges may be removed from verified truth,
    never added from release intent alone.
15. Funnel telemetry stays outside operational D1 and cannot silently report success when unavailable.
16. Weekly blind accuracy draws require verdicts; a missed verdict window creates a triage incident.
17. Guard findings and operational alerts enter the durable two-agent triage queue.
18. Every cutover has a tested rollback and the legacy estate remains authoritative until its gate passes.
19. Every recurring grocery executor is derived from or bidirectionally verified against one Git authority.
20. Every judgment prompt is versioned and its deployed hash must match the active agent registry.
21. Every agent run has a durable ledger; ledger failure authorizes diagnostic reads only, never mutation.
22. CI workflow identity is endpoint-scoped and every agent has an explicit capability set and audit identity.
23. Judgment agents execute only on their registered plane. The authoritative PC plane uses per-agent,
    DPAPI-protected HMAC identities, the same server-owned capabilities, leases, fencing, evaluations and
    budgets as OIDC; GitHub-hosted execution is a manually selected fallback and never dispatches itself.
24. Publishable recipe content exists only in immutable staging batches and deterministic guards own promotion.
25. Unbounded historical analytics and archive queries never run against operational D1.
26. A quarterly automated scratch restore must pass; absence or failure creates a durable operational incident.
27. Mutating scheduled work must hold the current D1 lease fence, and deployments must drain non-safe leases.
28. A configuration cannot activate until its content-addressed R2 recovery object passes read-after-write verification.
29. A retired transition executor is a durable tombstone and schedule synchronization cannot reactivate it.
30. Browser capture state is journaled in local SQLite; append-only adapter events and compressed JSON are
    recovery artifacts, not competing state authorities.
31. A validated browser batch is matched and promoted by its Cloudflare Workflow. The PC does not need to
    remain online after seal, and failed incomplete pipelines are redispatched by Cloudflare cron.
32. Browser seal pins the exact configuration ID and content hash. Validation retries, cloud matching,
    promotion proof and configuration compaction must honor that immutable pin rather than reread active state.
33. A direct-upload retry never revives an expired URL or overwrites an earlier attempt. Each renewal receives
    a new object key; Cloudflare deletes only expired/rejected keys not referenced by finalized evidence.

## Migration calendar and retirement

The approved estimate is four to six months. Milestone 0 proves DDL, capacity, route, entitlements, threat
model, and restore (1–2 weeks). Milestone 1 runs shadow ingestion and installs configuration single-sourcing
(2–3 weeks plus 14 clean days), retiring hand-edited legacy config. Milestone 2 establishes semantic engine
parity (3–5 weeks including 14 clean days). Milestone 3 unifies recipes, Top 5, rotation, feeds, and Ghost
reconciliation (2–3 weeks). Milestone 4 completes four direct-browser weekly cycles and retires the capture
git-bus and paired Windows schedules (4 weeks, overlapping Milestone 5). Milestone 5 runs beta and a 30-day
release soak, then retires static board/feed read paths and Ghost board injection (3–4 weeks plus soak).
Milestone 6 moves recipes and tools individually (3–4 weeks). Milestone 7 archives the old publication stack
after chaos and rollback drills (1–2 weeks plus rollback window).
