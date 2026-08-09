# Grocery platform v3 implementation status

## Implemented and locally testable

- The working v2 foundation: strict TypeScript workspace, D1/R2, immutable observations and releases, atomic
  publication, chunked ingest, deterministic replay, integer money, server-owned guards, and responsive board.
- Forward-only V3 schema for `taxonomy_path`, explicit release batch snapshots, release Top 5/rotation tables,
  Ghost reconciliation attempts, weekly accuracy draws/verdicts, and durable triage items.
- Git-authored configuration under `platform/config`, a byte-identical legacy generator, a checked manifest,
  and D1 deployment of categories, commodities, 48,975 unique match rules, and active known-wrong names.
- GitHub OIDC verification bound to issuer, audience, repository, workflow, expiry, signature, and replay nonce;
  PC/local HMAC credentials remain separately scoped.
- Workers Analytics Engine funnel events for view, tool-use, signup-click, and join-attempt with no D1 writes.
- Explicit promoted-batch selection and a release hash that binds both manifest and sorted batch IDs.
- Shelf taxonomy capture plus an aisle second-opinion rule that cannot flip when evidence is absent.
- Ghost visibility reconciliation with live re-read, attempt ledger, triage on failure, and remove-only badge truth.
- Weekly deterministic blind sampling, per-cell verdicts, overdue incidents, and a 95% Wilson interval on status.
- Guard findings automatically create triage queue items; internal doctor, triage, accuracy, reject, and
  reconciliation endpoints are available through the unified `pnpm tc` operator CLI.
- Architecture decisions, AI operator contract, and failure-class catalog live in-repo.

## External and time-based gates still open

- Wrangler authentication, production D1/R2/Analytics Engine provisioning, private Ghost credentials, and an
  immutable GitHub repository ID must be configured before a remote deployment.
- The entitlement adapter still needs its seven live Ghost/member states, including mobile Safari.
- A real remote restore drill, beta Workers Route, route rollback rehearsal, and alert delivery integration remain.
- Milestone evidence still requires 14 clean shadow-ingest days, four direct Chrome weekly cycles, 30 daily
  published releases, weekly accuracy verdict completion, and the final chaos drills.

The PowerShell/Git/Ghost estate remains authoritative. Code completion is not cutover approval, and no legacy
publisher, capture task, route, or static read path is retired until the applicable milestone is signed off.
