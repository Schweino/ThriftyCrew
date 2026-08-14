import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";
import { authoredRuleMatchAuthority, compileProductMatcher, evaluateAisleFamilyEvidence, type AisleFamily } from "@thriftycrew/engine";
import type { WorkerEnv } from "./env";
import { archiveConfiguration, verifyConfigurationArchive } from "./configuration-archive";
import { reconcileInactiveConfigurationDecisions } from "./match-decision-reconciliation";

interface ProductRow {
  product_id: string;
  name: string;
  normalized_name: string;
  taxonomy_path: string | null;
}

interface MatcherDefinition {
  commodityId: string;
  includes: string[];
  excludes: string[];
  priority: number;
  categoryId: string | null;
}

const matcherCache = new Map<string, { matcher: ReturnType<typeof compileProductMatcher>; definitions: Map<string, MatcherDefinition> }>();

async function configurationMatcher(env: WorkerEnv, configurationId: string, configurationHash: string) {
  const cached = matcherCache.get(configurationHash);
  if (cached) return cached;
  await archiveConfiguration(env, configurationId);
  const archive = await env.DB.prepare(
    "SELECT object_key, byte_length, sha256 FROM configuration_archives WHERE configuration_id = ?1 AND status = 'verified'",
  ).bind(configurationId).first<{ object_key: string; byte_length: number; sha256: string }>();
  if (!archive) throw new Error(`configuration ${configurationId} has no verified matcher archive`);
  const verified = await verifyConfigurationArchive(env, configurationId, archive.object_key, archive.byte_length, archive.sha256);
  if (verified.schemaVersion !== 2 || verified.payload.configuration.content_hash !== configurationHash) {
    throw new Error(`configuration ${configurationId} matcher archive does not match its seal-time content hash`);
  }
  const commodities = new Map(verified.payload.commodities.map((commodity) => [String(commodity.id), commodity]));
  const definitions = new Map<string, MatcherDefinition>();
  for (const rule of verified.payload.rules) {
    const commodity = commodities.get(rule.commodity_id);
    if (!commodity) throw new Error(`configuration matcher rule references missing commodity ${rule.commodity_id}`);
    const definition = definitions.get(rule.commodity_id) ?? {
      commodityId: rule.commodity_id,
      includes: [], excludes: [],
      priority: Number(commodity.match_priority ?? 0),
      categoryId: typeof commodity.category_id === "string" ? commodity.category_id : null,
    };
    (rule.kind === "include" ? definition.includes : definition.excludes).push(rule.pattern);
    definitions.set(rule.commodity_id, definition);
  }
  const result = { matcher: compileProductMatcher([...definitions.values()]), definitions };
  matcherCache.clear();
  matcherCache.set(configurationHash, result);
  return result;
}

export interface CaptureConfigurationPin {
  configurationId: string;
  configurationHash: string;
}

export async function assertCaptureConfigurationPin(env: WorkerEnv, pin: CaptureConfigurationPin): Promise<void> {
  const configuration = await env.DB.prepare(
    "SELECT content_hash FROM configuration_versions WHERE id = ?1",
  ).bind(pin.configurationId).first<{ content_hash: string }>();
  if (!configuration) throw new Error(`pinned configuration ${pin.configurationId} is missing`);
  if (configuration.content_hash !== pin.configurationHash) {
    throw new Error(`pinned configuration ${pin.configurationId} content hash changed`);
  }
}

export async function runCloudCaptureMatch(env: WorkerEnv, batchId: string, pin: CaptureConfigurationPin): Promise<{ status: "passed" | "failed"; runId: string; matched: number; products: number }> {
  const batch = await env.DB.prepare("SELECT id, source_id, status FROM capture_batches WHERE id = ?1").bind(batchId).first<{ id: string; source_id: string; status: string }>();
  if (!batch || !["validated", "promoted", "superseded"].includes(batch.status)) throw new Error(`capture ${batchId} cannot be cloud-matched from ${batch?.status ?? "missing"}`);
  await assertCaptureConfigurationPin(env, pin);
  const configuration = { id: pin.configurationId, content_hash: pin.configurationHash };
  const products = await env.DB.prepare(`
    WITH ranked AS (
      SELECT p.id AS product_id, pv.name, pv.normalized_name, pv.taxonomy_path,
             ROW_NUMBER() OVER (PARTITION BY p.id ORDER BY o.captured_at DESC, o.id DESC) AS ordinal
        FROM capture_batch_observations member
        JOIN observations o ON o.id = member.observation_id
        JOIN product_versions pv ON pv.id = o.product_version_id
        JOIN products p ON p.id = pv.product_id
       WHERE member.batch_id = ?1
    )
    SELECT product_id, name, normalized_name, taxonomy_path FROM ranked WHERE ordinal = 1 ORDER BY product_id
  `).bind(batchId).all<ProductRow>();
  const { matcher, definitions } = await configurationMatcher(env, configuration.id, configuration.content_hash);
  const decisions: Array<{ productId: string; commodityId: string; decidedBy: "rule" | "aisle"; reason: string }> = [];
  const unmatched: Array<Record<string, unknown>> = [];
  const collisions: Array<Record<string, unknown>> = [];
  const aisleRejected: Array<Record<string, unknown>> = [];
  const nonFood = new Set(["household", "personal", "baby", "pet"]);
  for (const product of products.results) {
    const outcome = matcher(product.name);
    if (outcome.status === "collision") {
      collisions.push({ productId: product.product_id, name: product.name, candidates: outcome.candidates });
      continue;
    }
    if (outcome.status !== "matched" || !outcome.commodityId) {
      unmatched.push({ productId: product.product_id, name: product.name });
      continue;
    }
    const definition = definitions.get(outcome.commodityId)!;
    const expectedFamily: AisleFamily = nonFood.has(definition.categoryId ?? "") ? definition.categoryId as AisleFamily : "food";
    const additionalAllowedFamilies: AisleFamily[] = [];
    if (outcome.commodityId === "protein-bars" || outcome.commodityId === "hand-soap") additionalAllowedFamilies.push("personal");
    if (outcome.commodityId === "facial-tissues") additionalAllowedFamilies.push("household");
    const aisle = evaluateAisleFamilyEvidence(product.taxonomy_path ?? undefined, expectedFamily, additionalAllowedFamilies);
    if (aisle.status === "rejected") {
      aisleRejected.push({ productId: product.product_id, name: product.name, commodityId: outcome.commodityId, taxonomyPath: product.taxonomy_path, reason: aisle.reason });
      continue;
    }
    // The authored name rule is authoritative. Taxonomy is independent
    // corroborating/rejecting evidence and must not turn the product-level
    // match into a requirement on every later observation version.
    decisions.push({ productId: product.product_id, commodityId: outcome.commodityId, decidedBy: authoredRuleMatchAuthority(aisle), reason: `Cloud-authored first-match precedence${product.taxonomy_path ? `; shelf taxonomy examined: ${aisle.reason}` : "; no shelf taxonomy supplied"}` });
  }
  const inputHash = await digestHex(stableJson({
    batchId, sourceId: batch.source_id, configurationId: configuration.id, configurationHash: configuration.content_hash,
    products: products.results.map((product) => [product.product_id, product.normalized_name, product.taxonomy_path]),
    decisions: decisions.map((decision) => [decision.productId, decision.commodityId, decision.decidedBy]),
  }));
  const runId = `match_${inputHash.slice(0, 32)}`;
  const existing = await env.DB.prepare("SELECT status FROM match_runs WHERE id = ?1").bind(runId).first<{ status: "passed" | "failed" }>();
  if (existing) return { status: existing.status, runId, matched: decisions.length, products: products.results.length };
  const statements: D1PreparedStatement[] = [];
  for (const decision of decisions) {
    const decisionId = await deterministicId("match", configuration.id, decision.productId, decision.commodityId);
    statements.push(env.DB.prepare(`INSERT INTO match_decisions
      (id, product_id, commodity_id, configuration_id, decided_by, reason)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      ON CONFLICT(id) DO UPDATE SET decided_by = excluded.decided_by, reason = excluded.reason,
        decided_at = CURRENT_TIMESTAMP, superseded_at = NULL
      WHERE match_decisions.decided_by <> excluded.decided_by
         OR match_decisions.reason <> excluded.reason
         OR match_decisions.superseded_at IS NOT NULL`)
      .bind(decisionId, decision.productId, decision.commodityId, configuration.id, decision.decidedBy, decision.reason));
  }
  for (let offset = 0; offset < statements.length; offset += 80) await env.DB.batch(statements.slice(offset, offset + 80));
  await env.DB.prepare(`UPDATE match_decisions SET superseded_at = CURRENT_TIMESTAMP
    WHERE configuration_id = ?2 AND superseded_at IS NULL
      AND product_id IN (
        SELECT DISTINCT p.id FROM capture_batch_observations member
        JOIN observations o ON o.id = member.observation_id
        JOIN product_versions pv ON pv.id = o.product_version_id
        JOIN products p ON p.id = pv.product_id WHERE member.batch_id = ?1
      ) AND NOT EXISTS (
        SELECT 1 FROM json_each(?3) desired
         WHERE json_extract(desired.value, '$[0]') = match_decisions.product_id
           AND json_extract(desired.value, '$[1]') = match_decisions.commodity_id
      )`)
    .bind(batchId, configuration.id, stableJson(decisions.map((decision) => [decision.productId, decision.commodityId]))).run();
  const status = collisions.length === 0 ? "passed" as const : "failed" as const;
  const detail = {
    sourceId: batch.source_id, executionPlane: "cloud-capture-workflow", precedence: "authored commodity match_priority",
    unmatchedExamples: unmatched.slice(0, 100), collisionExamples: collisions.slice(0, 100), aisleRejectedExamples: aisleRejected.slice(0, 100),
  };
  await env.DB.prepare(`INSERT INTO match_runs
    (id, batch_id, configuration_id, input_hash, status, product_count, matched_count,
     unmatched_count, collision_count, aisle_rejected_count, detail_json)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)`)
    .bind(runId, batchId, configuration.id, inputHash, status, products.results.length, decisions.length, unmatched.length, collisions.length, aisleRejected.length, stableJson(detail)).run();
  if (status === "failed") {
    const triageId = await deterministicId("triage", "match-run", runId);
    await env.DB.prepare(`INSERT OR IGNORE INTO triage_items
      (id, source_kind, source_ref, severity, status, title, evidence_json)
      VALUES (?1, 'operational_alert', ?2, 'hard', 'open', ?3, ?4)`)
      .bind(triageId, runId, `Cloud matching found ${collisions.length} unresolved collisions`, stableJson(detail)).run();
  }
  if (status === "passed") await reconcileInactiveConfigurationDecisions(env.DB);
  return { status, runId, matched: decisions.length, products: products.results.length };
}

export async function promoteCloudMatchedCapture(env: WorkerEnv, batchId: string, matchRunId: string, configurationId: string): Promise<"promoted" | "superseded"> {
  const batch = await env.DB.prepare("SELECT source_id, status FROM capture_batches WHERE id = ?1").bind(batchId).first<{ source_id: string; status: string }>();
  if (!batch) throw new Error(`capture ${batchId} is missing`);
  if (batch.status === "promoted" || batch.status === "superseded") return batch.status;
  if (batch.status !== "validated") throw new Error(`capture ${batchId} cannot promote from ${batch.status}`);
  const matching = await env.DB.prepare(
    "SELECT status FROM match_runs WHERE id = ?1 AND batch_id = ?2 AND configuration_id = ?3",
  ).bind(matchRunId, batchId, configurationId).first<{ status: string }>();
  if (matching?.status !== "passed") throw new Error(`capture ${batchId} does not have passed matching`);
  const previous = await env.DB.prepare("SELECT id FROM capture_batches WHERE source_id = ?1 AND status = 'promoted' AND id <> ?2").bind(batch.source_id, batchId).all<{ id: string }>();
  const statements = previous.results.map((row) => env.DB.prepare("UPDATE capture_batches SET status = 'superseded' WHERE id = ?1 AND status = 'promoted'").bind(row.id));
  statements.push(env.DB.prepare("UPDATE capture_batches SET status = 'promoted', promoted_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'validated'").bind(batchId));
  await env.DB.batch(statements);
  await reconcileInactiveConfigurationDecisions(env.DB);
  return "promoted";
}
