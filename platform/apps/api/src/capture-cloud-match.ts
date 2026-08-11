import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";
import { compileProductMatcher, evaluateAisleFamilyEvidence, type AisleFamily } from "@thriftycrew/engine";
import type { WorkerEnv } from "./env";

interface ProductRow {
  product_id: string;
  name: string;
  normalized_name: string;
  taxonomy_path: string | null;
}

interface RuleRow {
  commodity_id: string;
  category_id: string | null;
  match_priority: number;
  kind: "include" | "exclude";
  pattern: string;
}

export async function runCloudCaptureMatch(env: WorkerEnv, batchId: string): Promise<{ status: "passed" | "failed"; runId: string; matched: number; products: number }> {
  const batch = await env.DB.prepare("SELECT id, source_id, status FROM capture_batches WHERE id = ?1").bind(batchId).first<{ id: string; source_id: string; status: string }>();
  if (!batch || !["validated", "promoted", "superseded"].includes(batch.status)) throw new Error(`capture ${batchId} cannot be cloud-matched from ${batch?.status ?? "missing"}`);
  const configuration = await env.DB.prepare("SELECT id, content_hash FROM configuration_versions WHERE active = 1").first<{ id: string; content_hash: string }>();
  if (!configuration) throw new Error("active configuration is missing");
  const products = await env.DB.prepare(`
    WITH ranked AS (
      SELECT p.id AS product_id, pv.name, pv.normalized_name, pv.taxonomy_path,
             ROW_NUMBER() OVER (PARTITION BY p.id ORDER BY o.captured_at DESC, o.id DESC) AS ordinal
        FROM observations o
        JOIN product_versions pv ON pv.id = o.product_version_id
        JOIN products p ON p.id = pv.product_id
       WHERE o.batch_id = ?1
    )
    SELECT product_id, name, normalized_name, taxonomy_path FROM ranked WHERE ordinal = 1 ORDER BY product_id
  `).bind(batchId).all<ProductRow>();
  const rules = await env.DB.prepare(`
    SELECT c.id AS commodity_id, c.category_id, c.match_priority, r.kind, r.pattern
      FROM commodities c
      JOIN (
        SELECT configuration_id, commodity_id, kind, pattern FROM match_rules
        UNION ALL
        SELECT membership.configuration_id, definition.commodity_id, definition.kind, definition.pattern
          FROM configuration_match_rules membership
          JOIN match_rule_definitions definition ON definition.id = membership.definition_id
      ) r ON r.configuration_id = c.configuration_id AND r.commodity_id = c.id
     WHERE c.configuration_id = ?1 AND c.active = 1
     ORDER BY c.match_priority DESC, c.id, r.kind, r.pattern
  `).bind(configuration.id).all<RuleRow>();
  const definitions = new Map<string, { commodityId: string; includes: string[]; excludes: string[]; priority: number; categoryId: string | null }>();
  for (const rule of rules.results) {
    const definition = definitions.get(rule.commodity_id) ?? { commodityId: rule.commodity_id, includes: [], excludes: [], priority: rule.match_priority, categoryId: rule.category_id };
    (rule.kind === "include" ? definition.includes : definition.excludes).push(rule.pattern);
    definitions.set(rule.commodity_id, definition);
  }
  const matcher = compileProductMatcher([...definitions.values()]);
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
    decisions.push({ productId: product.product_id, commodityId: outcome.commodityId, decidedBy: aisle.status === "confirmed" ? "aisle" : "rule", reason: `Cloud-authored first-match precedence${product.taxonomy_path ? `; shelf taxonomy examined: ${aisle.reason}` : "; no shelf taxonomy supplied"}` });
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
    statements.push(env.DB.prepare(`UPDATE match_decisions SET superseded_at = CURRENT_TIMESTAMP
      WHERE product_id = ?1 AND superseded_at IS NULL AND (configuration_id <> ?2 OR commodity_id <> ?3)`)
      .bind(decision.productId, configuration.id, decision.commodityId));
    statements.push(env.DB.prepare(`INSERT INTO match_decisions
      (id, product_id, commodity_id, configuration_id, decided_by, reason)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      ON CONFLICT(id) DO UPDATE SET decided_by = excluded.decided_by, reason = excluded.reason,
        decided_at = CURRENT_TIMESTAMP, superseded_at = NULL`)
      .bind(decisionId, decision.productId, decision.commodityId, configuration.id, decision.decidedBy, decision.reason));
  }
  for (let offset = 0; offset < statements.length; offset += 80) await env.DB.batch(statements.slice(offset, offset + 80));
  await env.DB.prepare(`UPDATE match_decisions SET superseded_at = CURRENT_TIMESTAMP
    WHERE configuration_id = ?2 AND superseded_at IS NULL
      AND product_id IN (
        SELECT DISTINCT p.id FROM observations o JOIN product_versions pv ON pv.id = o.product_version_id
        JOIN products p ON p.id = pv.product_id WHERE o.batch_id = ?1
      ) AND product_id NOT IN (SELECT value FROM json_each(?3))`)
    .bind(batchId, configuration.id, stableJson(decisions.map((decision) => decision.productId))).run();
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
  return { status, runId, matched: decisions.length, products: products.results.length };
}

export async function promoteCloudMatchedCapture(env: WorkerEnv, batchId: string): Promise<"promoted" | "superseded"> {
  const batch = await env.DB.prepare("SELECT source_id, status FROM capture_batches WHERE id = ?1").bind(batchId).first<{ source_id: string; status: string }>();
  if (!batch) throw new Error(`capture ${batchId} is missing`);
  if (batch.status === "promoted" || batch.status === "superseded") return batch.status;
  if (batch.status !== "validated") throw new Error(`capture ${batchId} cannot promote from ${batch.status}`);
  const matching = await env.DB.prepare("SELECT status FROM match_runs WHERE batch_id = ?1 ORDER BY created_at DESC LIMIT 1").bind(batchId).first<{ status: string }>();
  if (matching?.status !== "passed") throw new Error(`capture ${batchId} does not have passed matching`);
  const previous = await env.DB.prepare("SELECT id FROM capture_batches WHERE source_id = ?1 AND status = 'promoted' AND id <> ?2").bind(batch.source_id, batchId).all<{ id: string }>();
  const statements = previous.results.map((row) => env.DB.prepare("UPDATE capture_batches SET status = 'superseded' WHERE id = ?1 AND status = 'promoted'").bind(row.id));
  statements.push(env.DB.prepare("UPDATE capture_batches SET status = 'promoted', promoted_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'validated'").bind(batchId));
  await env.DB.batch(statements);
  return "promoted";
}
