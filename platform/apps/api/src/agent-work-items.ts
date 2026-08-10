import {
  accuracyVerdictsSchema,
  contentBatchAuditSchema,
  contentBatchItemsSchema,
  pullRequestProposalSchema,
  recipeDedupSchema,
  recipeMapSchema,
  recipeSourceCandidatesSchema,
  triagePlanSchema,
  type AgentWorkItemClaim,
  type AgentWorkItemComplete,
  type AgentWorkItemFail,
} from "@thriftycrew/contracts";
import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";
import type { MutationIdentity } from "./env";

interface RegistryRow {
  id: string;
  output_contract: string;
  execution_config_hash: string;
  criticality: "safety" | "operational" | "optional";
  prompt_sha256: string;
  input_contracts_json: string;
}

interface WorkSeed {
  sourceKind: "triage-item" | "accuracy-draw" | "recipe-request" | "source-sentinel-result" | "release-status";
  sourceRef: string;
  stage: string;
  input: unknown;
  severity: "safety" | "operational" | "optional";
}

const RECIPE_CHAIN: Record<string, string | undefined> = {
  "recipe-sourcer": "recipe-deduper",
  "recipe-deduper": "recipe-mapper",
  "recipe-mapper": "recipe-writer",
  "recipe-writer": "recipe-auditor",
  "recipe-auditor": undefined,
};

async function activeAgent(db: D1Database, agentId: string): Promise<RegistryRow> {
  const row = await db.prepare(
    `SELECT id, output_contract, execution_config_hash, criticality, prompt_sha256, input_contracts_json
       FROM agent_registry WHERE id = ?1 AND active = 1 AND enabled = 1`,
  ).bind(agentId).first<RegistryRow>();
  if (!row || !row.execution_config_hash) throw new Error("agent is unknown, disabled, or missing an execution configuration hash");
  return row;
}

async function seedsFor(db: D1Database, agentId: string): Promise<WorkSeed[]> {
  if (agentId === "triage-reviewer") {
    const rows = await db.prepare(
      `SELECT id, source_kind, source_ref, severity, title, evidence_json, created_at
         FROM triage_items WHERE status = 'open' ORDER BY created_at, id LIMIT 25`,
    ).all<Record<string, unknown>>();
    return rows.results.map((row) => ({
      sourceKind: "triage-item", sourceRef: String(row.id), stage: "review",
      severity: String(row.severity) === "hard" || String(row.severity) === "safety" ? "safety" : "operational",
      input: { contract: "triage-item-v1", item: row },
    }));
  }
  if (agentId === "triage-developer") {
    const rows = await db.prepare(
      `SELECT id, source_kind, source_ref, severity, title, evidence_json, plan_ref, resolution_json, updated_at
         FROM triage_items WHERE status = 'planned' ORDER BY updated_at, id LIMIT 25`,
    ).all<Record<string, unknown>>();
    return rows.results.map((row) => ({
      sourceKind: "triage-item", sourceRef: String(row.id), stage: "develop",
      severity: String(row.severity) === "hard" || String(row.severity) === "safety" ? "safety" : "operational",
      input: { contract: "triage-plan-v1", item: row, plan: JSON.parse(String(row.resolution_json ?? "{}")) },
    }));
  }
  if (agentId === "accuracy-headless") {
    const rows = await db.prepare(
      `SELECT id, market_id, sample_size, seed_commitment, opened_at, due_at
         FROM accuracy_draws WHERE status = 'open' ORDER BY opened_at, id LIMIT 10`,
    ).all<Record<string, unknown>>();
    return rows.results.map((row) => ({ sourceKind: "accuracy-draw", sourceRef: String(row.id), stage: "judge", severity: "safety", input: { contract: "accuracy-blind-sample-v1", draw: row } }));
  }
  if (agentId === "source-sentinel-investigator") {
    const rows = await db.prepare(
      `SELECT id, source_id, contract_version, status, checks_json, evidence_json, observed_at
         FROM source_sentinel_results WHERE status = 'fail' ORDER BY observed_at DESC LIMIT 10`,
    ).all<Record<string, unknown>>();
    return rows.results.map((row) => ({ sourceKind: "source-sentinel-result", sourceRef: String(row.id), stage: "investigate", severity: "operational", input: { contract: "source-sentinel-result-v1", result: row } }));
  }
  if (agentId === "post-publish-reviewer") {
    const row = await db.prepare(
      `SELECT release.id, release.published_at, release.configuration_id, release.input_hash, release.summary_json
         FROM current_releases current JOIN releases release ON release.id = current.release_id
        WHERE current.market_id = 'omaha'`,
    ).first<Record<string, unknown>>();
    return row ? [{ sourceKind: "release-status", sourceRef: String(row.id), stage: "review", severity: "safety", input: { contract: "release-status-v1", release: row } }] : [];
  }
  if (agentId === "recipe-sourcer") {
    const rows = await db.prepare(
      `SELECT id, request_text, source_ref, requested_at
         FROM recipe_suggestion_requests WHERE status = 'queued' ORDER BY requested_at, id LIMIT 10`,
    ).all<Record<string, unknown>>();
    return rows.results.map((row) => ({ sourceKind: "recipe-request", sourceRef: String(row.id), stage: "source", severity: "optional", input: { contract: "recipe-source-request-v1", request: row } }));
  }
  return [];
}

async function enqueue(db: D1Database, agent: RegistryRow, seed: WorkSeed, adapterVersion: string, inputContract: string): Promise<string> {
  const inputJson = stableJson(seed.input);
  const fingerprint = await digestHex(stableJson({
    agentId: agent.id,
    sourceKind: seed.sourceKind,
    sourceRef: seed.sourceRef,
    stage: seed.stage,
    adapterVersion,
    inputContract,
    executionConfigHash: agent.execution_config_hash,
    input: seed.input,
  }));
  const id = await deterministicId("agent-work", agent.id, fingerprint);
  await db.prepare(
    `INSERT INTO agent_work_items
       (id, agent_id, source_kind, source_ref, stage, adapter_version, input_contract,
        output_contract, execution_config_hash, execution_fingerprint, severity, input_json)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
     ON CONFLICT(execution_fingerprint) DO NOTHING`,
  ).bind(id, agent.id, seed.sourceKind, seed.sourceRef, seed.stage, adapterVersion, inputContract,
    agent.output_contract, agent.execution_config_hash, fingerprint, seed.severity, inputJson).run();
  return id;
}

export async function claimAgentWorkItem(db: D1Database, identity: MutationIdentity, body: AgentWorkItemClaim): Promise<Record<string, unknown> | null> {
  if (identity.registeredAgentId !== body.agentId) throw new Error("an agent may only claim its own registered work");
  const agent = await activeAgent(db, body.agentId);
  if (body.adapterVersion !== "phase2-v1") throw new Error("agent adapter version is not registered");
  const inputContracts = JSON.parse(agent.input_contracts_json) as string[];
  if (!inputContracts.includes(body.inputContract)) throw new Error("agent input contract is not registered");
  const evaluation = await db.prepare(
    `SELECT id FROM agent_evaluations
      WHERE agent_id = ?1 AND execution_config_hash = ?2 AND passed = 1
      ORDER BY evaluated_at DESC LIMIT 1`,
  ).bind(agent.id, agent.execution_config_hash).first<{ id: string }>();
  if (!evaluation) throw new Error("agent execution is blocked until this exact execution configuration passes evaluation");
  for (const seed of await seedsFor(db, body.agentId)) await enqueue(db, agent, seed, body.adapterVersion, body.inputContract);
  const now = new Date();
  await db.prepare(
    `UPDATE agent_work_items SET state = 'retryable', lease_id = NULL, lease_expires_at = NULL,
       updated_at = CURRENT_TIMESTAMP, last_error = 'lease expired'
     WHERE agent_id = ?1 AND state = 'leased' AND lease_expires_at <= ?2`,
  ).bind(agent.id, now.toISOString()).run();
  const candidate = await db.prepare(
    `SELECT id FROM agent_work_items
      WHERE agent_id = ?1 AND state IN ('queued', 'retryable') AND available_at <= ?2
        AND attempt_count < max_attempts
      ORDER BY CASE severity WHEN 'safety' THEN 0 WHEN 'operational' THEN 1 ELSE 2 END,
               created_at, id LIMIT 1`,
  ).bind(agent.id, now.toISOString()).first<{ id: string }>();
  if (!candidate) return null;
  const leaseId = crypto.randomUUID();
  const expiresAt = new Date(now.getTime() + body.leaseSeconds * 1000).toISOString();
  const claimed = await db.prepare(
    `UPDATE agent_work_items SET state = 'leased', lease_id = ?2,
       lease_generation = lease_generation + 1, lease_expires_at = ?3,
       attempt_count = attempt_count + 1, github_run_id = ?4, updated_at = CURRENT_TIMESTAMP
     WHERE id = ?1 AND state IN ('queued', 'retryable')
     RETURNING *`,
  ).bind(candidate.id, leaseId, expiresAt, identity.githubRunId ?? null).first<Record<string, unknown>>();
  if (!claimed) return null;
  const inputHash = await digestHex(String(claimed.input_json));
  await db.prepare(
    `INSERT INTO agent_work_item_attempts
       (id, work_item_id, lease_id, lease_generation, github_run_id, status, input_hash, started_at)
     VALUES (?1, ?2, ?3, ?4, ?5, 'leased', ?6, ?7)`,
  ).bind(await deterministicId("agent-attempt", candidate.id, String(claimed.lease_generation)), candidate.id,
    leaseId, claimed.lease_generation, identity.githubRunId ?? null, inputHash, now.toISOString()).run();
  return { ...claimed, input: JSON.parse(String(claimed.input_json)), input_json: undefined, evaluationId: evaluation.id };
}

export function validateAgentOutput(contract: string, value: unknown, sourceRef: string, agentId: string): unknown {
  if (contract === "triage-plan-v1") {
    const plan = triagePlanSchema.parse(value);
    if (plan.triageId !== sourceRef) throw new Error("triage plan belongs to a different triage item");
    return plan;
  }
  if (contract === "pull-request-v1") {
    const proposal = pullRequestProposalSchema.parse(value);
    for (const file of proposal.files) {
      const normalized = file.path.replaceAll("\\", "/");
      if (normalized.startsWith("/") || normalized.includes("../") || normalized.startsWith(".github/workflows/") || /(^|\/)(\.env|\.dev\.vars|secrets?)(\/|$)/i.test(normalized)) throw new Error(`pull-request path is forbidden: ${file.path}`);
      if (agentId === "source-sentinel-investigator" && !(
        normalized === "platform/config/source-contracts.json"
        || normalized.startsWith("platform/apps/daily/src/source-contracts")
        || normalized.startsWith("platform/agents/evals/source-sentinel-investigator")
        || normalized.startsWith("grocery/tests/fixtures/")
      )) throw new Error(`source sentinel path is outside its allowlist: ${file.path}`);
    }
    return proposal;
  }
  if (contract === "accuracy-verdicts-v1") {
    const verdicts = accuracyVerdictsSchema.parse(value);
    if (verdicts.drawId !== sourceRef) throw new Error("accuracy verdicts belong to a different draw");
    return verdicts;
  }
  if (contract === "recipe-source-candidates-v1") return recipeSourceCandidatesSchema.parse(value);
  if (contract === "recipe-dedup-v1") return recipeDedupSchema.parse(value);
  if (contract === "recipe-map-v1") return recipeMapSchema.parse(value);
  if (contract === "content-items-v1") return contentBatchItemsSchema.parse(value);
  if (contract === "content-audit-v1") return contentBatchAuditSchema.parse(value);
  throw new Error(`output contract ${contract} has no server validator`);
}

async function enqueueRecipeNext(db: D1Database, completed: Record<string, unknown>, output: unknown): Promise<string | undefined> {
  const nextAgentId = RECIPE_CHAIN[String(completed.agent_id)];
  if (!nextAgentId) return undefined;
  const next = await activeAgent(db, nextAgentId);
  await enqueue(db, next, {
    sourceKind: "recipe-request",
    sourceRef: String(completed.source_ref),
    stage: nextAgentId.replace("recipe-", ""),
    severity: "optional",
    input: { contract: String(completed.output_contract), previousWorkItemId: completed.id, output, nextAgentId, nextPromptHash: next.prompt_sha256 },
  }, String(completed.adapter_version), nextAgentId === "recipe-mapper" ? "recipe-dedup-v1" : String(completed.output_contract));
  return nextAgentId;
}

async function stageAuditedRecipeBatch(db: D1Database, completed: Record<string, unknown>, auditValue: unknown): Promise<{ contentBatchId: string; status: string }> {
  const input = JSON.parse(String(completed.input_json)) as { output?: unknown; nextPromptHash?: string };
  const itemsDocument = contentBatchItemsSchema.parse(input.output);
  const audit = contentBatchAuditSchema.parse(auditValue);
  if (audit.auditorAgentId !== "recipe-auditor" || audit.promptHash !== input.nextPromptHash) throw new Error("recipe audit identity or prompt hash does not match the active chain input");
  const inputHash = await digestHex(stableJson(input));
  const contentHash = await digestHex(stableJson(itemsDocument));
  const batchId = await deterministicId("content", "recipe-pack", String(completed.source_ref), contentHash);
  await db.prepare(
    `INSERT INTO content_batches
       (id, kind, status, input_hash, prompt_hash, source_refs_json, created_by, content_hash)
     VALUES (?1, 'recipe-pack', 'staging', ?2, ?3, ?4, 'recipe-writer', ?5)
     ON CONFLICT(id) DO NOTHING`,
  ).bind(batchId, inputHash, audit.promptHash, stableJson([`recipe-request://${String(completed.source_ref)}`]), contentHash).run();
  const itemStatements = await Promise.all(itemsDocument.items.map(async (item, ordinal) => db.prepare(
    `INSERT INTO content_batch_items (batch_id, slug, ordinal, content_json, content_hash)
     VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT(batch_id, slug) DO NOTHING`,
  ).bind(batchId, item.slug, ordinal, stableJson(item), await digestHex(stableJson(item)))));
  for (let offset = 0; offset < itemStatements.length; offset += 90) await db.batch(itemStatements.slice(offset, offset + 90));
  const hardFindings = audit.findings.filter((finding) => finding.severity === "hard").length;
  const warningFindings = audit.findings.filter((finding) => finding.severity === "warning").length;
  const auditId = await deterministicId("content-audit", batchId, audit.promptHash);
  const status = hardFindings > 0 ? "rejected" : "audited";
  await db.batch([
    db.prepare(
      `INSERT INTO content_batch_audits
         (id, batch_id, auditor_agent_id, prompt_hash, findings_json, hard_findings, warning_findings)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT(id) DO NOTHING`,
    ).bind(auditId, batchId, audit.auditorAgentId, audit.promptHash, stableJson(audit.findings), hardFindings, warningFindings),
    db.prepare("UPDATE content_batches SET status = ?2, sealed_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'staging'").bind(batchId, status),
    db.prepare("UPDATE recipe_suggestion_requests SET status = ?2, content_batch_id = ?3, updated_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(completed.source_ref, status === "audited" ? "staged" : "rejected", batchId),
  ]);
  return { contentBatchId: batchId, status };
}

export async function completeAgentWorkItem(db: D1Database, identity: MutationIdentity, workItemId: string, body: AgentWorkItemComplete): Promise<Record<string, unknown>> {
  const current = await db.prepare("SELECT * FROM agent_work_items WHERE id = ?1").bind(workItemId).first<Record<string, unknown>>();
  if (!current) throw new Error("work item not found");
  if (identity.registeredAgentId !== current.agent_id) throw new Error("an agent may only complete its own work");
  if (current.state === "completed" && current.lease_id === body.leaseId && Number(current.lease_generation) === body.leaseGeneration) return { idempotent: true, workItemId, state: "completed" };
  const output = validateAgentOutput(String(current.output_contract), body.output, String(current.source_ref), String(current.agent_id));
  const outputJson = stableJson(output);
  const outputHash = await digestHex(outputJson);
  const finishedAt = new Date().toISOString();
  const update = await db.prepare(
    `UPDATE agent_work_items SET state = 'completed', output_json = ?5, completed_at = ?6,
       updated_at = CURRENT_TIMESTAMP
     WHERE id = ?1 AND agent_id = ?2 AND state = 'leased' AND lease_id = ?3
       AND lease_generation = ?4 AND lease_expires_at > ?6`,
  ).bind(workItemId, identity.registeredAgentId, body.leaseId, body.leaseGeneration, outputJson, finishedAt).run();
  if ((update.meta.changes ?? 0) !== 1) {
    await db.prepare(
      `UPDATE agent_work_item_attempts SET status = 'late-discarded', output_hash = ?4,
         detail_json = ?5, finished_at = ?6
       WHERE work_item_id = ?1 AND lease_id = ?2 AND lease_generation = ?3`,
    ).bind(workItemId, body.leaseId, body.leaseGeneration, outputHash, stableJson({ reason: "lease fence rejected completion" }), finishedAt).run();
    throw new Error("completion was discarded because the lease is stale or expired");
  }
  await db.prepare(
    `UPDATE agent_work_item_attempts SET status = 'completed', output_hash = ?4, finished_at = ?5
     WHERE work_item_id = ?1 AND lease_id = ?2 AND lease_generation = ?3`,
  ).bind(workItemId, body.leaseId, body.leaseGeneration, outputHash, finishedAt).run();
  let nextAgentId: string | undefined;
  let contentBatch: { contentBatchId: string; status: string } | undefined;
  if (current.agent_id === "triage-reviewer") {
    await db.prepare(
      `UPDATE triage_items SET status = 'planned', plan_ref = ?2, resolution_json = ?3,
         updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'open'`,
    ).bind(current.source_ref, `agent-work://${workItemId}`, outputJson).run();
    nextAgentId = "triage-developer";
  }
  if (current.agent_id === "recipe-auditor") contentBatch = await stageAuditedRecipeBatch(db, current, output);
  else if (String(current.agent_id).startsWith("recipe-")) nextAgentId = await enqueueRecipeNext(db, current, output);
  return { idempotent: false, workItemId, state: "completed", outputHash, nextAgentId: nextAgentId ?? null, contentBatch: contentBatch ?? null };
}

export async function failAgentWorkItem(db: D1Database, identity: MutationIdentity, workItemId: string, body: AgentWorkItemFail): Promise<Record<string, unknown>> {
  const current = await db.prepare("SELECT * FROM agent_work_items WHERE id = ?1").bind(workItemId).first<Record<string, unknown>>();
  if (!current) throw new Error("work item not found");
  if (identity.registeredAgentId !== current.agent_id) throw new Error("an agent may only fail its own work");
  const retry = body.retryable && Number(current.attempt_count) < Number(current.max_attempts);
  const state = retry ? "retryable" : "deadletter";
  const finishedAt = new Date().toISOString();
  const delaySeconds = Math.min(3600, 60 * 2 ** Math.max(0, Number(current.attempt_count) - 1));
  const availableAt = new Date(Date.now() + delaySeconds * 1000).toISOString();
  const update = await db.prepare(
    `UPDATE agent_work_items SET state = ?5, last_error = ?6, available_at = ?7,
       lease_id = NULL, lease_expires_at = NULL, updated_at = CURRENT_TIMESTAMP
     WHERE id = ?1 AND agent_id = ?2 AND state = 'leased' AND lease_id = ?3 AND lease_generation = ?4`,
  ).bind(workItemId, identity.registeredAgentId, body.leaseId, body.leaseGeneration, state, body.reason, availableAt).run();
  if ((update.meta.changes ?? 0) !== 1) throw new Error("failure was discarded because the lease is stale");
  await db.prepare(
    `UPDATE agent_work_item_attempts SET status = 'failed', detail_json = ?4, finished_at = ?5
     WHERE work_item_id = ?1 AND lease_id = ?2 AND lease_generation = ?3`,
  ).bind(workItemId, body.leaseId, body.leaseGeneration, stableJson({ reason: body.reason, retryable: retry }), finishedAt).run();
  return { workItemId, state, retryAt: retry ? availableAt : null };
}
