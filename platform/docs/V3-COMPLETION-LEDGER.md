# Grocery Platform V3 completion ledger

This is the authoritative completion ledger for the V3 Plan of Record. A row is complete only when its
implementation is deployed and the named live evidence exists. Code completion, deployment, cutover, and
retirement are deliberately separate states.

## Current program state

- Core V3 shadow Worker, D1, R2 evidence, Analytics Engine, API, board, configuration authority, release
  model, guards, triage, accuracy tables, Ghost reconciliation module, and operator CLI are deployed.
- The legacy PowerShell/Git/Ghost estate remains authoritative.
- Customer traffic has not been routed to V3.
- The live evidence windows have not completed.

## Plan-of-record requirements

| Requirement | Implementation | Live evidence | State |
| --- | --- | --- | --- |
| Strict TypeScript monorepo and pinned toolchain | Deployed | CI green on `main` | complete |
| D1/R2/Worker write boundary | Deployed | Authenticated remote replay and rejected wrong-role fixtures | complete |
| Immutable capture batches and observations | Deployed | Seven promoted legacy-bridge batches | shadow-only |
| Direct headless source through batch protocol | Missing | No direct-source promoted batch | open |
| Direct Chrome capture through batch protocol | Missing | No direct-browser promoted batch | open |
| Git-authored configuration generates legacy and D1 copies | Deployed | One active configuration and byte-identical generated legacy files | complete |
| Promoted-batch input snapshot and atomic release pointer | Deployed | Published release `rel_555c2c6eb2730017e4ae796b` | complete |
| Native engine semantic parity | Partial; current release is built by the migration bridge | No 14-day zero-unexplained-diff window | open |
| Release-owned recipes, Top 5, rotation, and feed | Deployed from bridge artifacts | Deliberate guard-failure and surface-freeze drill pending | shadow-only |
| Ghost rotation intent-versus-truth reconciliation | Module deployed | Live credentials, clobber drill, and verified reconciliation pending | open |
| EntitlementProvider seven-state adapter | Classifier tests only | Live Ghost/member and mobile Safari matrix pending | open |
| Workers Routes preview and customer cutover | Worker.dev preview only | Route proof and rollback rehearsal pending | open |
| Funnel telemetry outside D1 | Deployed | Production event accepted and dashboard dataset present | complete |
| Weekly blind accuracy draw and Wilson interval | Deployed | First 100-cell draw exists; verdict completion cadence pending | shadow-only |
| Durable guard/alert triage loop | D1 queue deployed | Automated reviewer/developer drain and delivery alert pending | open |
| Job ledger, primary GitHub schedule, and Worker watchdog | Tables/endpoints partial | All production schedule rows currently have zero runs | open |
| Nightly D1 export and quarterly restore drill | Missing | No backup export or scratch restore | open |
| Complete founding-bug fixture port | Partial | PowerShell guards still protect unported classes | open |
| `tc` operator surface from the Plan of Record | Partial | Dispatch and direct capture commands missing | open |
| Four direct weekly Chrome cycles | Missing | 0 of 4 | time-gated |
| Four weekly boundaries during board beta | Missing | 0 of 4 | time-gated |
| Fourteen clean shadow-ingest days | Not started | 0 of 14 | time-gated |
| Fourteen clean semantic-parity days | Not started | 0 of 14 | time-gated |
| Thirty consecutive published daily releases | Not started | 0 of 30 | time-gated |
| Chaos and rollback drills | Missing | No completed drill ledger | open |
| Legacy retirement with tombstones and rollback window | Not authorized | No subsystem has passed its retirement gate | open |

## Completion rule

V3 is complete only when every row above is `complete`, the customer route serves V3, all required live
windows are recorded from production evidence, and every retired legacy subsystem has a tombstone naming its
successor and rollback procedure.
