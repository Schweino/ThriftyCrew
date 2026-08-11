# ADR 0007: Unified orchestration and bounded operational state

## Decision

D1 is the concurrency authority for every mutating execution plane. PC jobs, registered-agent cycles and
Cloudflare Workflows acquire a resource lease before work begins. Each takeover increments a fencing token.
Scheduled mutation clients carry that job identity and fence on later requests; the Worker renews a current
lease and rejects an expired or superseded fence. Local filesystem locks and Task Scheduler `IgnoreNew`
remain useful first-line protections, but they are not the correctness boundary.

Deployments call the authenticated preflight endpoint before Wrangler. Any active job, Workflow or maintenance
lease blocks the deployment, preventing a Worker release from resetting an in-flight D1 export or restore.
The initial rollout alone may use the explicit bootstrap flag because the old Worker does not expose the
preflight route.

Authored configuration is copied to a content-addressed R2 object and read-after-write verified before a new
configuration can activate. D1 keeps the operational representation needed by the active system; R2 keeps the
large immutable recovery representation. No historical configuration is compacted until its R2 object and a
rehydration proof exist.

Capacity state uses a median recent growth rate plus projected exhaustion. A projection within 180 days arms
planning even below 70% current usage; a projection within 30 days is critical. Static percentage thresholds
remain backstops.

Transition executors retire only through server-evaluated evidence. A retirement creates a durable tombstone,
and schedule synchronization cannot reactivate it. The OS task is disabled only after the same readiness result
passes; failed retirement coordination must be rolled back rather than silently leaving split authority.

A daily cross-plane proof checks the active configuration archive, release pointer coherence, hard pricing
guards, recipe completeness, backup RPO, execution fencing, D1 capacity and the independent browser SLA. A
failed required check enters the durable operational-alert and agent-triage path.

## Consequences

- A second executor stands down instead of duplicating capture, publication, email or agent work.
- A stale process cannot resume mutations after another holder receives a newer fence.
- Deployments may be delayed by legitimate long-running maintenance; this is intentional and visible.
- R2 archive verification precedes destructive compaction, so this decision does not authorize deleting
  current D1 history.
- Evidence gates, not calendar estimates or operator preference, remain the authority for legacy retirement.

