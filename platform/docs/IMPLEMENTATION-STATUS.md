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
- Authoritative local schedules with durable Worker job ledgers/watchdog, DPAPI credentials, bounded alerts,
  nightly D1 export, secondary private R2 replication, lifecycle policies, and scratch restore evidence.
  GitHub workflows remain checked-in manual fallbacks; automatic hosted-runner dispatch is fail-closed.
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
- Off-hour, Central-time V3 Windows schedules plus a local Family Fare paced sweep.
- Agents-as-code registry, hashed prompts, fixtures, budgets, token cost ledger, scoped local HMAC and fallback OIDC.
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
- Query-efficiency hardening: indexed known-wrong lookups split by stable identity channel, batch/product and
  promoted-source indexes, keyset configuration recovery, and planner optimization after migration.
- Exact-input work reuse: identical match runs return before writes, unchanged decisions do not update, and
  an already-published native release is detected from its cheap immutable identity before loading candidates.
- Public immutable payloads use explicit edge caching, strong content-hash ETags, conditional 304s and
  release headers. Private member, internal and status routes remain `no-store`.
- D1 insights are evaluated daily against Git-authored budgets; findings reconcile through one durable incident.
  Browser queue drains are bounded so one PC task cannot consume an unbounded backlog window.

## Phase 2 judgment execution plane

- Ten agents run in bounded local cycles with separate DPAPI-protected HMAC identities. The Worker binds each
  identity to its active PC registry entry and applies the same capabilities, evaluations, leases, fencing and
  budgets; the Worker remains the only production write boundary.
- Ten thin GitHub caller workflows and one reusable runner remain as manual fallback artifacts. OIDC still
  verifies both caller and reusable identities when an operator explicitly chooses that fallback.
- Exact semantic execution hashes bind model, fallback, reasoning, prompt and contracts. Operational schedule
  and budget edits do not invalidate evaluation evidence.
- Every agent has an agent-specific deterministic and prompt-injection corpus. Claims fail closed until the
  exact execution hash has a passing live candidate evaluation recorded in D1.
- Durable work items use idempotent fingerprints, leases, fencing, retries, dead letters and late-result
  discard. Chained triage and recipe stages are picked up by bounded local cycles; the 15-minute Worker no
  longer turns queue presence into unbounded GitHub workflow dispatch.
- Structured outputs are validated server-side. Pull-request agents are limited to approved paths, apply
  proposals only in isolated local worktrees, execute the complete quality gate, open a GitHub PR, and have
  no merge or deploy capability.
- Recipe waves snapshot the pre-wave release and correct failures through a new immutable release. Login
  canaries enforce privacy and same-profile timing. Routine and incident reserve budgets are isolated.

See `docs/HARDENING-STATUS.md` for the implementation and retirement boundary.
# V4 incremental ingredient catalog (2026-08-14)

Phase 0 baseline is recorded with verified checkpoint `checkpoint_2026-08-14-8abc7c94-aa90-414b-b8ba-8a2c6c75017f`; the two current V2 origins agreed before implementation. The additive V4 schema, flags-off code, store-agent registry, direct per-ingredient publisher, exact dependency resume, Node supervisor, challenge callback, benchmark, and distinct recipe verifier are locally implemented. Clean migration replay through 0073, registry/config/schedule checks, live ChatGPT verifier evaluation, typechecks, 476 tests, dry-run production builds, and PowerShell parser checks pass.

Production traffic remains on V3. The V4 flags remain `off`; the pending publication job is preserved. UI/V2 cutover and legacy-writer enforcement are prohibited until current-board backfill and semantic parity pass, followed by shadow store comparison, one- and ten-ingredient canaries, the complete recipe-to-publication flow, the release-blocking 30-item benchmark, two-origin verification, and a rollback drill. The 30-day read-only legacy soak begins only after those gates pass; no retirement date is approved yet.

### Truthful current-board backfill

Migration 0075 stages the current V2 board without converting missing display cells into availability claims. A row whose observation is still the exact priced `release_cells` member is recorded as `priced_provenance_recovered`; an absent cell is recorded only as non-public `legacy_unknown`. Neither state is terminal V4 evidence. Every ingredient/store/definition tuple receives one deduplicated producer work item, and independent verifier work is required before a cell can become `terminal_verified`.

Migration 0077 pins each run to the content-addressed board object and verifies the board hash on every import page, so later release-payload compaction cannot move a backfill to a newer board. Evidence submission accepts an adapter chunk, not a caller-declared outcome. The API rederives the result from the current ingredient definition, locked queries, canonical store policy, complete raw/projected/excluded counts, pagination, product and availability identity, exact integer price semantics, package basis, and ad dates. Blocks become durable `challenged`; rejected, excluded, ambiguous, or incomplete facts become `needs_operator`. Only a complete `priced` or `not_found` derivation queues a distinct verifier, which must submit a newer independent chunk reproducing the frozen result.

Operators page the import to keep D1 requests bounded:

```text
pnpm tc ingredient backfill-v4 initialize
pnpm tc ingredient backfill-v4 import <run-id> 0 25
pnpm tc ingredient backfill-v4 progress <run-id>
pnpm tc ingredient backfill-v4 claim <producer-agent-id> <owner> 50
pnpm tc ingredient backfill-v4 heartbeat <owner> 900
pnpm tc ingredient backfill-v4 producer-submit <lease-fenced-adapter-artifact.json>
pnpm tc ingredient backfill-v4 verifier-submit <independent-adapter-artifact.json>
pnpm tc ingredient backfill-v4 requeue <run-id> <commodity-id> <store-id> <adjudication-id> <adapter_repaired|challenge_resolved> <resolution-reason>
```

A `needs_operator` or `challenged` cell is recoverable only after an actual typed resolution. `adapter_repaired` means the deployed adapter now preserves the previously missing immutable raw/source facts; `challenge_resolved` records an acknowledged retailer challenge resolution. Free-form reason text never excludes a candidate. Requeue is idempotent by adjudication ID, retains the prior work identity, and creates a new dedupe/lease/generation fence that must capture fresh checked evidence; old evidence is retained and can never be reused as the verifier pass.

The progress response deliberately reports `semanticParity` and `terminalEvidenceReadiness` separately. `promotionAllowed` is true only when the exact expected cell count is present and every cell is independently terminal-verified; extra, partial, mixed, challenged, stale, or `legacy_unknown` evidence fails closed. Import and capture may run with all public V4 flags off, but no V4 public pointer or UI route may be enabled from backfill staging data.
