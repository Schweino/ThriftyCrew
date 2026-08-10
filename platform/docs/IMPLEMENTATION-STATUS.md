# Grocery Platform V3 implementation status

## Implemented, deployed, and exercised

- Strict TypeScript workspace; D1/R2/Worker authority boundary; immutable captures, observations, match
  decisions, configurations, releases, input snapshots, and atomic current-release pointer.
- GitHub OIDC for engine mutations, separately scoped HMAC capture/operator credentials, audit events,
  idempotency, replay protection, and source-specific capture authorization.
- One Git-authored configuration source generating both legacy compatibility files and the active D1 version.
- Direct server capture for Baker's, Family Fare, and Hy-Vee, plus direct Omaha Chrome capture for Aldi,
  Fareway, Sam's Club, and Walmart. Browser jobs use an immutable local queue, screenshots, manifests, hashes,
  leases, exponential retry, receipts, permanent rejection, and a separate engine-owned promotion step.
- Native matching and aisle-family second opinion, taxonomy paths, integer price bases, known-wrong exclusion,
  promoted-batch selection, native recipe costs, Top 5, rotation, feeds, and release guards.
- Ghost intent-versus-truth reconciliation with live reread and remove-only badge behavior; entitlement adapter
  and browser-visible member-state routes.
- External exact-route beta verification, release rollback drill, Analytics Engine funnel events, deterministic
  weekly blind accuracy sample, Wilson interval, durable alerts/triage, and typed reviewer-to-developer handoff.
- GitHub schedules and recovery dispatch, job ledger/watchdog, sanitized private Actions diagnostics, nightly
  D1 export, secondary private R2 replication, lifecycle policies, and scratch restore evidence.
- Operator CLI for every platform operation, complete founding-bug port ledger, six chaos proofs, and automated
  daily/weekly milestone evidence accrual.
- Production-scale recovery proof: GitHub run `31350242781` acquired all three server sources, attested and
  promoted them, published `rel_native_50f3f39fd758249c9542`, reconciled Ghost, recorded zero-diff direct
  parity, accrued evidence, and closed its durable job ledger successfully with no diagnostic tail.

## Evidence gates still open

- 14 consecutive clean shadow-ingest days: 1 recorded.
- 14 consecutive zero-diff native parity days: 1 recorded.
- Four direct Chrome weekly cycles: 0 strict full-session cycles recorded; the earlier partial bootstrap week was intentionally invalidated, with strict counting beginning 2026-08-12.
- Four completed blind-accuracy weekly cycles: 1 recorded.
- 30 consecutive successful beta daily releases: 1 recorded.
- Four closed beta weeks: 0 recorded; the earlier incomplete week correctly failed.
- Live entitlement verification: five of seven states recorded. Expired and cancelled require real Ghost/member
  lifecycle transitions and may not be fabricated.

All V3 implementation work is deployed and the live API/member routes and board beta are on V3. The legacy publication/capture estate is retained
only as the approved rollback path until the evidence gates above close. Final retirement and tombstones are
therefore not yet authorized, even though the remaining waits are evidence/time rather than missing platform
implementation.

## Infrastructure hardening implemented after the V3 baseline

- Truthful transition inventory and bidirectional schedule drift enforcement across GitHub, Worker and PC.
- Off-hour, Central-time V3 schedules plus a cloud Family Fare paced sweep.
- Agents-as-code registry, hashed prompts, fixtures, budgets, token cost ledger and workflow-scoped OIDC.
- Read-only diagnostic fallback when the agent ledger is unavailable; no invisible mutation path.
- Immutable recipe content batches with separate AI audit and deterministic promotion authority.
- Expand/contract forward migration governance and automated quarterly scratch restore Workflow.
- Isolated D1 Sessions replication canary; no premature public-route cutover.
- Byte/growth-based archival forecasts, protected-reference manifests, verified R2 Parquet upload path and
  deterministic source-contract sentinels.
- An hourly Cloudflare-side browser SLA independently detects an offline PC or missing strict weekly capture
  after the Saturday retry deadline and reports its exact remote promotion, matching and evidence gaps.
- Capture-time accuracy contract for every strict browser pull: exact visible/structured source agreement,
  truth-preserving row provenance, continuous Omaha location/mode checks, complete worklist and bounded
  pagination accounting, deterministic anomaly/risk selection, and an independent targeted second pass.
  Local queue admission and the Worker both reproduce the R2-bound report; unresolved checks fail the
  `batch-browser-accuracy` guard beginning with the 2026-08-12 strict cycle.

## Phase 2 judgment execution plane

- Ten thin GitHub caller workflows route through one reusable runner. OIDC verifies both the registered caller
  and reusable workflow identities; the Worker remains the only production write boundary.
- Exact semantic execution hashes bind model, fallback, reasoning, prompt and contracts. Operational schedule
  and budget edits do not invalidate evaluation evidence.
- Every agent has an agent-specific deterministic and prompt-injection corpus. Claims fail closed until the
  exact execution hash has a passing live candidate evaluation recorded in D1.
- Durable work items use idempotent fingerprints, leases, fencing, retries, dead letters and late-result
  discard. Chained triage and recipe stages dispatch immediately and also have a scheduled retry sweep.
- Structured outputs are validated server-side. Pull-request agents are limited to approved paths, execute the
  complete quality gate, open GitHub App-authored PRs and have no deploy capability.
- Recipe waves snapshot the pre-wave release and correct failures through a new immutable release. Login
  canaries enforce privacy and same-profile timing. Routine and incident reserve budgets are isolated.

See `docs/HARDENING-STATUS.md` for the implementation and retirement boundary.
