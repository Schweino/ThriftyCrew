# Infrastructure hardening status

## Scope and authority

This document records hardening phases H0-H6 on top of the deployed V3 platform. It does not accelerate or
waive V3 evidence gates. `config/schedules.json` owns recurring grocery schedules, `config/agents.json` owns
judgment-agent definitions and prompts live under `agents/`. D1 is the operational ledger; R2 owns backup,
evidence and verified archive objects.

## H0 - baseline truth

- `config/transition-inventory.json` records the evidence counts observed on 2026-08-10 and distinguishes
  retirement blockers from implementation work.
- Every current `SMP *` Windows task is represented in schedule authority. The Facebook reel is explicitly
  adjacent scope and does not block grocery retirement.
- Legacy grocery tasks remain `transition` until their named V3 evidence gates pass.

## H1/H2 - schedule and credential authority

- `tc schedules check` performs bidirectional drift detection across GitHub workflow cron entries, Wrangler
  cron triggers and `grocery/expected-automations.json`. A rogue or missing executor entry fails CI.
- GitHub schedules use `America/Chicago` and avoid top-of-hour execution for V3 workloads.
- The Family Fare paced sweep has a cloud three-hour replacement before the Windows task may retire.
- GitHub OIDC trusts exact infrastructure workflows plus ten registered thin agent callers. Agent callers must
  invoke the one approved reusable runner, and both the caller `workflow_ref` and reusable `job_workflow_ref`
  are verified before any capability is granted. The restore workflow can only trigger the deterministic drill.

## H3 - agents as code and plane split

- Ten judgment agents have hashed prompts, semantic execution hashes, agent-specific adversarial evaluation
  corpora, structured input/output contracts, model/fallback/reasoning choices, effective-dated token pricing,
  capabilities, criticality and split routine/reserve budgets.
- An exact execution-hash evaluation must pass before a work item can be claimed. The server owns work-item
  idempotency, leases, fencing, retries, dead letters, severity and chained dispatch; late completions are
  retained as evidence but cannot mutate current state.
- The triage reviewer-to-developer and recipe sourcer-to-auditor chains dispatch immediately, with a Worker
  retry sweep for queued work. Registered agents cannot select their own input contract or workflow identity.
- PC has no judgment agent in the registry. Browser capture and accuracy remain deterministic clients.
- The triage developer and source-sentinel investigator are pull-request-only, restricted by server and staging
  path allowlists, and run the full repository gate before a GitHub App opens a PR. They cannot deploy.

## H4 - immutable content batches

- Recipe-pack content is staged in immutable D1 batches with item hashes, an agent audit and a separate
  deterministic promotion gate.
- The deterministic gate validates duplicate identities, commodity mappings, ingredient coherence and
  provenance. An LLM audit cannot promote content by itself.
- Rejected or promoted batch items cannot be changed or deleted; a correction requires a new batch.
- Recipe publication waves record an immutable pre-wave release snapshot. A failed wave is corrected by
  cloning that snapshot into a new validated release; a superseded release pointer is never reused.
- Login-canary evidence stores only Ghost member IDs/tags and probe timing, rejects email-shaped fields, and
  requires two same-profile probes 9-30 minutes apart.

## H5 - database hardening and recovery

- Migration `0016` is additive. `scripts/check-migrations.mjs` enforces forward expand/contract policy and
  requires a durable restore-proof reference before a future contract migration.
- `D1RestoreDrillWorkflow` selects the latest completed R2 SQL backup, creates an explicitly named scratch D1,
  imports it through Cloudflare's D1 import API, compares six core table counts and the current release ID/hash,
  records durable evidence and deletes only the exact scratch UUID.
- Production drill `d1-restore-2026-Q3-a20` passed on 2026-08-10. It restored backup
  `backup_d1-backup-manual-8a1f...`, matched all six backup-derived table counts plus release ID/hash, recovered
  ten oversized release payloads, recorded durable evidence, and removed the scratch D1 and attempt-scoped R2
  staging objects. No restore scratch databases remained after cleanup.
- `/api/v2/replica-canary` is an isolated `first-primary` Sessions API pilot. No public release route is moved
  to replicas until canary evidence proves a benefit without consistency findings.

## H6 - capacity and source contracts

- Daily archival forecasts use database bytes, the configured 10 GiB limit, measured growth, protected release
  references and projected exhaustion rather than a fixed row threshold.
- Archive execution is disarmed below 70% capacity. When armed, a manifest can select only observations older
  than 18 months that are not referenced by a release. Parquet uploads require header/trailer verification,
  SHA-256, R2 reread/size verification and an immutable manifest.
- The Parquet builder pins its runtime in `scripts/requirements-archive.txt`; operators install that file before
  creating an archive object so local and recovery runs use the same Arrow version.
- Source-contract checks are deterministic and run before each server-source ingestion. Failures create durable
  operational alerts; the AI investigator is a read-only second stage.

## Remaining calendar proof

V3 legacy retirement still depends on the live evidence counters in `IMPLEMENTATION-STATUS.md`. Hardening code
may deploy while those counters accrue, but no transition executor is retired early.
