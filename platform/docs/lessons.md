# Failure-class catalog

Each lesson names the v3 constraint and the test or guard that prevents recurrence. Add new failures here only
with an enforcing fixture; prose by itself is not a safeguard.

| Failure class | V3 constraint | Enforcement |
| --- | --- | --- |
| Partial capture presented as a full refresh | Coverage mode and term/page outcomes are immutable batch facts | `batch-completeness`, `batch-collapse` |
| Thin capture evicts a complete observation | Complete/ad-only observations are protected from partial/targeted eviction | `selectWinner` fixture, `release-capture-eviction` |
| Cat litter crowned as baking soda | Store shelf taxonomy is captured and aisle flips require evidence | `evaluateAisleEvidence` fixtures, `release-aisle-taxonomy` |
| A previously adjudicated wrong product returns | Known-wrong rulings deploy with the configuration version | `release-known-wrong` |
| Rounded legacy unit prices fail exact native arithmetic | Legacy bridge alone receives a bounded 50-micro tolerance | domain arithmetic fixture, `release-basis` |
| Required recipe ingredient disappears from the total | Incomplete recipes never enter price-ranked surfaces | bridge fixture, `release-recipe-completeness` |
| Grocery moves while recipe/feed/rotation stays stale | All five payloads and release-owned counts validate before one pointer swap | `release-surface-counts` |
| Multi-minute engine reads moving inputs | Promoted batch IDs are selected first and persisted as the input snapshot | release hash validation, `release-input-snapshot` |
| Client reports its own hard guard as passing | Hard guard results are server-owned | authenticated API regression exercise |
| Exact endpoint escapes authentication middleware | `/internal/*` is authenticated globally before role gates | auth regression exercise |
| Rotation intent disagrees with Ghost paywall truth | Reconciliation applies intent, verifies live truth, and badges use only the verified intersection | `mayShowFreeBadge` fixture, reconciliation ledger |
| Conversion remains unmeasurable | Funnel events write to Analytics Engine, never operational D1 | telemetry contract and binding |
| Board grades its own answers | Weekly seeded blind sample records external verdicts and a Wilson interval | accuracy service fixtures and `/v2/status` |
| Findings wait in email | Every guard finding creates a durable triage item | `upsertGuardResult` triage write |
| A leading-decimal package size becomes an 85 oz alternate and wins on a false 100x discount | Direct capture canonicalizes leading decimals, and a compatible normalized basis outranks ambiguous same-unit alternatives | direct-capture `.85 oz` fixture and `candidatePriceForUnit` normalized-basis fixture |
| A broad baby-food brand rule crowns toddler juice | Adjacent beverages are explicitly excluded while real puree products remain accepted | authored `baby-food` config matcher fixture |
| GitHub pulls direct server data but cannot ingest it | The engine OIDC role may write migration bridges and allowlisted direct-headless API/Freshop sources only; browser and arbitrary sources remain capture-scoped | `engineMayWriteCaptureSource` role/source fixture |
| A failed scheduled job is durable but silent until the next watchdog gap | Failed, timed-out, and missed job transitions immediately raise durable operational triage | terminal job-alert status fixture and `/internal/job-runs/:id` transition |
| `tc` cannot find a relative plan, evidence, or capture file from the documented platform working directory | Every user-supplied file path resolves from pnpm's original invocation directory (`INIT_CWD`), with absolute paths preserved | relative `tc capture validate fixtures/chaos/stale-browser-capture.json` smoke |
| A direct GitHub workflow is mistaken for an unregistered reusable agent because its token repeats the same workflow in `job_workflow_ref` | Agent-registry enforcement applies only when `job_workflow_ref` differs from the caller `workflow_ref`; both refs remain allowlisted and bound for real reusable agents | `isGithubReusableWorkflowCall` OIDC fixture |
| Restore normalization exceeds Worker CPU while constructing multipart padding or scanning dense SQL rows | Non-final R2 parts use byte-level SQL-whitespace padding, unchanged partitions bypass per-row JavaScript, source transforms stay at 512 KiB, and production declares the Paid-plan 30-second CPU budget explicitly | restore byte/count fixtures, partition-policy fixture, and deploy-time Wrangler limit validation |
| A morning direct capture is rejected as future data, or Freshop `ea`/`pk` packages disappear during normalization | Date-only evidence is canonicalized to the start of its Omaha calendar day, and Freshop package-count aliases normalize to `each` without inventing an item measure | Family Fare date and `ea`/`pk` direct-capture fixture |
| Repeated recovery experiments turn one active incident into an unactionable wall of stale alerts | Reconciliation closes backup failures on a later completed replica, retries exact multipart cleanup targets, and collapses failed restore attempts behind the newest still-open drill | `/internal/triage/reconcile` recovery proofs; the newest restore incident remains hard/open |
