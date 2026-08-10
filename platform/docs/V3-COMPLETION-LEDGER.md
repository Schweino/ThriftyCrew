# Grocery Platform V3 completion ledger

This is the authoritative completion ledger for the V3 Plan of Record. A row is complete only when its
implementation is deployed and the named live evidence exists. Code completion, deployment, cutover, and
retirement are deliberately separate states. Counts below are production facts as of 2026-08-09
America/Chicago; `/api/v2/status` and `tc evidence show` are the live authority after that date.

## Current program state

- The production Worker, D1, three R2 buckets, Analytics Engine dataset, backup Workflow, authenticated APIs,
  native engine, board beta, configuration authority, guards, triage, accuracy, Ghost reconciliation, job
  ledger, watchdog, and operator CLI are deployed.
- `www.thriftycrew.com/api/v2/*` and member-status paths are Worker Routes. The public beta board is live at
  `beta.thriftycrew.com`; the old board/publication estate remains available during the evidence window.
- Native release `rel_native_50f3f39fd758249c9542`, built from 11 promoted immutable batches, covers 507 commodities and seven Omaha stores.
  Direct server and direct Chrome captures are promoted through the same batch, matching, and guard protocol.
- V3 implementation is complete and deployed. Calendar evidence, two entitlement terminal states, and final
  retirement authorization remain open; those facts must not be simulated or backfilled.
- GitHub run `31350242781` exercised the complete scheduled path on `main`: verification, fresh server pulls,
  capture ingest/seal/promote, native publication, Ghost reread, zero-diff parity, evidence accrual, and a
  successful durable job finish. The preceding failures remain audited and were resolved only after this proof.

## Plan-of-record requirements

| Requirement | Implementation | Live evidence | State |
| --- | --- | --- | --- |
| Strict TypeScript monorepo and pinned toolchain | Deployed | GitHub `main` verification passes migrations, typecheck, tests, builds, and PowerShell 7 adapter checks | complete |
| D1/R2/Worker write boundary | Deployed | GitHub OIDC, scoped PC HMAC, replay protection, role rejection, and audited live mutations | complete |
| Immutable capture batches and observations | Deployed | 18 promoted batches; release inputs bind sorted promoted batch IDs before engine work | complete |
| Direct headless source through batch protocol | Deployed for Baker's, Family Fare, and Hy-Vee | Fresh source acquisition, ingest, matching, promotion, and native publication exercised from GitHub Actions | complete |
| Direct Chrome capture through batch protocol | Deployed for Aldi, Fareway, Sam's Club, and Walmart | Four Omaha in-store captures with screenshots, manifests, durable PC queue receipts, matching, and promotion; 1 of 4 weekly cycles | time-gated |
| Git-authored configuration generates legacy and D1 copies | Deployed | Active `cfg_153ffab51cb0c1c6692d`; generated compatibility files are checked in CI | complete |
| Promoted-batch input snapshot and atomic release pointer | Deployed | `rel_native_50f3f39fd758249c9542` published from 11 selected batches; interruption drill preserved the prior pointer | complete |
| Native engine semantic parity | Deployed; direct source is the native release input | Full 3,549-cell direct parity has zero diffs; production-scale parity snapshots omit recipe-only raw products; 1 of 14 consecutive required days | time-gated |
| Release-owned recipes, Top 5, rotation, and feed | Deployed | Current release has 542 recipes, 20 Top 5 rows, 20 rotation rows; freeze and wrong-input drills pass | complete |
| Ghost rotation intent-versus-truth reconciliation | Deployed | Current-release live reread has zero mismatches; clobber drill proves remove-only badge truth | complete |
| EntitlementProvider seven-state adapter | Deployed | Anonymous, free, paid, signed-out, and cookie-expired verified; real expired and cancelled accounts remain | evidence-open |
| Workers Routes preview and customer cutover | API/member routes and board beta deployed | External exact-route proof and rollback rehearsal pass; final old-board retirement waits for soak | beta |
| Funnel telemetry outside D1 | Deployed | Production events accepted by Workers Analytics Engine; operational D1 contains no funnel events | complete |
| Weekly blind accuracy draw and Wilson interval | Deployed | Blind `n=100` Omaha draw completed with status interval; 1 of 4 weekly cycles | time-gated |
| Durable guard/alert triage loop | Deployed | Findings and operational alerts create durable items; read-only review packets, typed plan hashes, audited resolution, reconciliation, and delivery are live | complete |
| Job ledger, primary GitHub schedule, and Worker watchdog | Deployed | Run `31350242781` completed the entire scheduled operation; heartbeats, recovery dispatches, immediate failure alerts, redacted Actions diagnostics, and watchdog alerts exercised | complete |
| Nightly D1 export and quarterly restore drill | Deployed | Primary and secondary private R2 copies, lifecycle policies, and a scratch-D1 restore proof exist | complete |
| Complete founding-bug fixture port | Deployed | Every entry in `founding-bug-port.json` is a ported proof or structural elimination; CI rejects pending entries | complete |
| `tc` operator surface from the Plan of Record | Deployed | Config, schedules, capture queue/ingest/match/promote/abandon, release, parity, evidence, accuracy, triage, backup, restore, jobs, Ghost, and drills are callable | complete |
| Four direct weekly Chrome cycles | Automated and first cycle complete | 1 of 4 | time-gated |
| Four weekly boundaries during board beta | Automated accrual deployed | 0 of 4 closed weeks; an incomplete prior week correctly records failure | time-gated |
| Fourteen clean shadow-ingest days | Automated accrual deployed | 1 of 14 | time-gated |
| Fourteen clean semantic-parity days | Automated accrual deployed | 1 of 14 | time-gated |
| Thirty consecutive published daily releases | Automated accrual deployed | 1 of 30 | time-gated |
| Chaos and rollback drills | Deployed | 6 of 4 required chaos classes and 1 of 1 route rollback pass | complete |
| Legacy retirement with tombstones and rollback window | Retirement code path intentionally gated | No subsystem may be retired before all applicable consecutive-day/week and entitlement evidence closes | evidence-open |

## Completion rule

V3 is complete only when every row above is `complete`, the required live windows are recorded from production
evidence, the real expired/cancelled entitlement states pass, and every retired legacy subsystem has a
tombstone naming its successor and rollback procedure. Until then, new V3 code may ship, but the remaining
legacy rollback estate must not be deleted.
