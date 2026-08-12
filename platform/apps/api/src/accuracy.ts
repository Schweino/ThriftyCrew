import type { AccuracyDrawCreate, AccuracyVerdicts } from "@thriftycrew/contracts";
import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";

interface CandidateCell {
  release_id: string;
  commodity_id: string;
  commodity_label: string;
  store_location_id: string;
  store_name: string;
  observation_id: string;
  product_url: string | null;
}

async function triageAccuracyVerdict(db: D1Database, drawId: string, lane: "uniform" | "risk", ordinal: number, verdict: "right" | "wrong" | "cannot_tell", evidence: Record<string, unknown>): Promise<void> {
  const sourceRef = `${drawId}#${lane}#${ordinal}`;
  if (verdict !== "wrong") {
    await db.prepare(
      `UPDATE triage_items SET status = 'resolved', resolved_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
        WHERE source_kind = 'accuracy_gap' AND source_ref = ?1 AND status <> 'resolved'`,
    ).bind(sourceRef).run();
    return;
  }
  const triageId = await deterministicId("triage", "accuracy-verdict", sourceRef);
  await db.prepare(
    `INSERT INTO triage_items (id, source_kind, source_ref, severity, title, evidence_json)
     VALUES (?1, 'accuracy_gap', ?2, ?3, ?4, ?5)
     ON CONFLICT(source_ref) DO UPDATE SET severity = excluded.severity, title = excluded.title,
       evidence_json = excluded.evidence_json, status = CASE WHEN triage_items.status = 'resolved' THEN 'open' ELSE triage_items.status END,
       updated_at = CURRENT_TIMESTAMP, resolved_at = NULL`,
  ).bind(triageId, sourceRef, "hard", `Wrong ${lane} accuracy sample ${ordinal}`, stableJson({ drawId, lane, ordinal, verdict, ...evidence })).run();
}

async function reconcileCannotTellDigest(db: D1Database, drawId: string): Promise<void> {
  const uniform = await db.prepare(
    `SELECT COUNT(*) AS reviewed, COALESCE(SUM(CASE WHEN verdict = 'cannot_tell' THEN 1 ELSE 0 END), 0) AS cannot_tell
       FROM operator_verdicts WHERE draw_id = ?1`,
  ).bind(drawId).first<{ reviewed: number; cannot_tell: number }>();
  const risk = await db.prepare(
    `SELECT COUNT(verdict) AS reviewed, COALESCE(SUM(CASE WHEN verdict = 'cannot_tell' THEN 1 ELSE 0 END), 0) AS cannot_tell
       FROM accuracy_risk_samples WHERE draw_id = ?1`,
  ).bind(drawId).first<{ reviewed: number; cannot_tell: number }>();
  const cannotTell = (uniform?.cannot_tell ?? 0) + (risk?.cannot_tell ?? 0);
  const sourceRef = `${drawId}#unverifiable-digest`;
  if (cannotTell === 0) {
    await db.prepare("UPDATE triage_items SET status = 'resolved', resolved_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE source_ref = ?1 AND status <> 'resolved'").bind(sourceRef).run();
    return;
  }
  const triageId = await deterministicId("triage", "accuracy-verdict", sourceRef);
  const evidence = { drawId, cannotTell, reviewed: (uniform?.reviewed ?? 0) + (risk?.reviewed ?? 0), policy: "one-digest-per-draw" };
  await db.prepare(
    `INSERT INTO triage_items (id, source_kind, source_ref, severity, title, evidence_json)
     VALUES (?1, 'accuracy_gap', ?2, 'warning', ?3, ?4)
     ON CONFLICT(source_ref) DO UPDATE SET title = excluded.title, evidence_json = excluded.evidence_json,
       status = CASE WHEN triage_items.status = 'resolved' THEN 'open' ELSE triage_items.status END,
       updated_at = CURRENT_TIMESTAMP, resolved_at = NULL`,
  ).bind(triageId, sourceRef, `${cannotTell} accuracy samples could not be independently verified`, stableJson(evidence)).run();
}

export interface AccuracySummary {
  drawId: string;
  releaseId: string;
  status: string;
  sampled: number;
  right: number;
  wrong: number;
  cannotTell: number;
  verdictsRecorded: number;
  accuracy: number | null;
  wilson95: { low: number; high: number } | null;
  dueAt: string;
}

export function wilsonInterval(successes: number, total: number, z = 1.959963984540054): { low: number; high: number } | null {
  if (total <= 0) return null;
  const proportion = successes / total;
  const zSquared = z * z;
  const denominator = 1 + zSquared / total;
  const center = (proportion + zSquared / (2 * total)) / denominator;
  const spread = (z * Math.sqrt((proportion * (1 - proportion) + zSquared / (4 * total)) / total)) / denominator;
  return { low: Math.max(0, center - spread), high: Math.min(1, center + spread) };
}

export async function createAccuracyDraw(db: D1Database, input: AccuracyDrawCreate): Promise<{ drawId: string; sampled: number; idempotent: boolean }> {
  const dailyRevalidation = input.protocolVersion === "winner-challenger-v1";
  const sameProtocolDraw = await db.prepare(
    `SELECT id, sampled_count FROM accuracy_draws
      WHERE market_id = ?1 AND seed = ?2 AND protocol_version = ?3`,
  ).bind(input.marketId, input.seed, input.protocolVersion).first<{ id: string; sampled_count: number }>();
  if (sameProtocolDraw) return { drawId: sameProtocolDraw.id, sampled: sameProtocolDraw.sampled_count, idempotent: true };
  const current = await db.prepare(
    "SELECT release_id FROM current_releases WHERE market_id = ?1",
  ).bind(input.marketId).first<{ release_id: string }>();
  if (!current) throw new Error("market has no published release");
  const drawId = await deterministicId("accuracy", input.marketId, current.release_id, input.seed, input.protocolVersion);
  const existing = await db.prepare("SELECT sampled_count FROM accuracy_draws WHERE id = ?1").bind(drawId).first<{ sampled_count: number }>();
  if (existing) return { drawId, sampled: existing.sampled_count, idempotent: true };

  const candidates = await db.prepare(
    `SELECT c.release_id, c.commodity_id, x.label AS commodity_label,
            c.store_location_id, l.display_name AS store_name,
            c.observation_id, pv.product_url
       FROM release_cells c
       JOIN commodities x ON x.id = c.commodity_id
       JOIN releases r ON r.id = c.release_id AND x.configuration_id = r.configuration_id
       JOIN store_locations l ON l.id = c.store_location_id
       JOIN observations o ON o.id = c.observation_id
       JOIN product_versions pv ON pv.id = o.product_version_id
      WHERE c.release_id = ?1 AND c.status = 'priced'
      ORDER BY c.commodity_id, c.store_location_id`,
  ).bind(current.release_id).all<CandidateCell>();
  const ranked = await Promise.all(candidates.results.map(async (cell) => ({
    cell,
    score: await digestHex(`${input.seed}\u001f${cell.commodity_id}\u001f${cell.store_location_id}`),
  })));
  ranked.sort((left, right) => left.score.localeCompare(right.score));
  const sampled = ranked.slice(0, Math.min(input.sampleSize, ranked.length));
  const statements: D1PreparedStatement[] = [db.prepare(
    `INSERT INTO accuracy_draws
       (id, market_id, release_id, seed, protocol_version, requested_size, sampled_count, due_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
  ).bind(drawId, input.marketId, current.release_id, input.seed, input.protocolVersion, input.sampleSize, sampled.length, input.dueAt)];
  sampled.forEach(({ cell }, ordinal) => statements.push(db.prepare(
    `INSERT INTO accuracy_draw_cells
       (draw_id, ordinal, release_id, commodity_id, store_location_id, observation_id)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  ).bind(drawId, ordinal, cell.release_id, cell.commodity_id, cell.store_location_id, cell.observation_id)));
  const riskBoard = await db.prepare(
    `WITH priced AS (
       SELECT c.commodity_id, c.store_location_id, c.observation_id, c.is_crown,
              c.display_per_unit_micros, c.reason_json,
              COUNT(*) OVER (PARTITION BY c.commodity_id) AS stores,
              AVG(c.display_per_unit_micros) OVER (PARTITION BY c.commodity_id) AS mean_price,
              ROW_NUMBER() OVER (PARTITION BY c.commodity_id ORDER BY c.display_per_unit_micros, c.store_location_id) AS price_rank
         FROM release_cells_with_reasons c WHERE c.release_id = ?1 AND c.status = 'priced'
     )
     SELECT *, CASE WHEN is_crown = 1 THEN 50 ELSE 0 END
          + CASE WHEN price_rank = 2 THEN 40 ELSE 0 END
          + CASE WHEN COALESCE(json_extract(reason_json, '$.basisSource'), 'normalized') <> 'normalized' THEN 100 ELSE 0 END
          + CASE WHEN mean_price > 0 AND display_per_unit_micros * 5 < mean_price THEN 200 ELSE 0 END AS risk_score
       FROM priced
      WHERE price_rank <= 2 OR COALESCE(json_extract(reason_json, '$.basisSource'), 'normalized') <> 'normalized'
         OR (mean_price > 0 AND display_per_unit_micros * 5 < mean_price)
      ORDER BY risk_score DESC, commodity_id, store_location_id LIMIT 1200`,
  ).bind(current.release_id).all<{ commodity_id: string; store_location_id: string; observation_id: string; is_crown: number; display_per_unit_micros: number; reason_json: string; stores: number; mean_price: number; price_rank: number; risk_score: number }>();
  const riskBoardRanked = await Promise.all(riskBoard.results.map(async (row) => ({ row, score: await digestHex(`${input.seed}\u001fboard-risk\u001f${row.commodity_id}\u001f${row.price_rank}\u001f${row.store_location_id}`) })));
  const selectedRiskBoard = dailyRevalidation
    ? riskBoardRanked.sort((left, right) => left.score.localeCompare(right.score)).slice(0, 100).map((item) => item.row)
    : riskBoard.results.filter((row) => row.risk_score >= 50).slice(0, 25);
  let riskOrdinal = 0;
  for (const row of selectedRiskBoard) {
    const id = await deterministicId("accuracy-risk", drawId, "board", String(riskOrdinal));
    statements.push(db.prepare(
      `INSERT INTO accuracy_risk_samples
         (id, draw_id, ordinal, lane, risk_kind, risk_score, release_id, commodity_id, store_location_id, observation_id, evidence_json)
       VALUES (?1, ?2, ?3, 'board', ?4, ?5, ?6, ?7, ?8, ?9, ?10)`,
    ).bind(id, drawId, riskOrdinal, row.risk_score >= 200 ? "extreme-price" : row.risk_score >= 100 ? "derived-basis" : row.price_rank === 2 ? "challenger" : "crown", row.risk_score, current.release_id, row.commodity_id, row.store_location_id, row.observation_id, stableJson({ revalidation: dailyRevalidation, priceRank: row.price_rank, isCrown: row.is_crown === 1, displayPerUnitMicros: row.display_per_unit_micros, comparedStores: row.stores, meanPriceMicros: row.mean_price, reason: JSON.parse(row.reason_json) })));
    riskOrdinal += 1;
  }
  const riskRecipes = dailyRevalidation ? { results: [] as Array<{ recipe_slug: string; status: string; batch_cost_minor: number | null; serving_cost_minor: number | null; risk_score: number; protein: string | null; rank: number | null }> } : await db.prepare(
    `SELECT costs.recipe_slug, costs.status, costs.batch_cost_minor, costs.serving_cost_minor,
            CASE WHEN ranked.recipe_slug IS NOT NULL THEN 200 WHEN costs.status <> 'complete' THEN 100 ELSE 25 END AS risk_score,
            ranked.protein, ranked.rank
       FROM release_recipe_costs costs
       LEFT JOIN release_top5 ranked ON ranked.release_id = costs.release_id AND ranked.recipe_slug = costs.recipe_slug
      WHERE costs.release_id = ?1 AND (ranked.recipe_slug IS NOT NULL OR costs.status <> 'complete')
      ORDER BY risk_score DESC, ranked.protein, ranked.rank, costs.recipe_slug LIMIT 25`,
  ).bind(current.release_id).all<{ recipe_slug: string; status: string; batch_cost_minor: number | null; serving_cost_minor: number | null; risk_score: number; protein: string | null; rank: number | null }>();
  for (const row of riskRecipes.results) {
    const id = await deterministicId("accuracy-risk", drawId, "recipe", String(riskOrdinal));
    statements.push(db.prepare(
      `INSERT INTO accuracy_risk_samples
         (id, draw_id, ordinal, lane, risk_kind, risk_score, release_id, recipe_slug, evidence_json)
       VALUES (?1, ?2, ?3, 'recipe', ?4, ?5, ?6, ?7, ?8)`,
    ).bind(id, drawId, riskOrdinal, row.protein ? "top5-recipe" : "incomplete-recipe", row.risk_score, current.release_id, row.recipe_slug, stableJson({ status: row.status, batchCostMinor: row.batch_cost_minor, servingCostMinor: row.serving_cost_minor, protein: row.protein, rank: row.rank })));
    riskOrdinal += 1;
  }
  const completeRecipePool = dailyRevalidation ? { results: [] as Array<{ recipe_slug: string; batch_cost_minor: number; serving_cost_minor: number }> } : await db.prepare(
    `SELECT costs.recipe_slug, costs.batch_cost_minor, costs.serving_cost_minor
       FROM release_recipe_costs costs
      WHERE costs.release_id = ?1 AND costs.status = 'complete'
        AND NOT EXISTS (SELECT 1 FROM release_top5 ranked WHERE ranked.release_id = costs.release_id AND ranked.recipe_slug = costs.recipe_slug)
      ORDER BY costs.recipe_slug`,
  ).bind(current.release_id).all<{ recipe_slug: string; batch_cost_minor: number; serving_cost_minor: number }>();
  const randomRecipes = await Promise.all(completeRecipePool.results.map(async (row) => ({ row, score: await digestHex(`${input.seed}\u001frecipe\u001f${row.recipe_slug}`) })));
  randomRecipes.sort((left, right) => left.score.localeCompare(right.score));
  for (const { row } of randomRecipes.slice(0, 10)) {
    const id = await deterministicId("accuracy-risk", drawId, "recipe", String(riskOrdinal));
    statements.push(db.prepare(
      `INSERT INTO accuracy_risk_samples
         (id, draw_id, ordinal, lane, risk_kind, risk_score, release_id, recipe_slug, evidence_json)
       VALUES (?1, ?2, ?3, 'recipe', 'random-complete-recipe', 50, ?4, ?5, ?6)`,
    ).bind(id, drawId, riskOrdinal, current.release_id, row.recipe_slug, stableJson({ batchCostMinor: row.batch_cost_minor, servingCostMinor: row.serving_cost_minor, sampling: "seeded-independent-recipe-lane" })));
    riskOrdinal += 1;
  }
  for (let offset = 0; offset < statements.length; offset += 90) await db.batch(statements.slice(offset, offset + 90));
  return { drawId, sampled: sampled.length, idempotent: false };
}

export async function readAccuracyDraw(db: D1Database, drawId?: string, reveal = false): Promise<Record<string, unknown> | null> {
  const draw = drawId
    ? await db.prepare("SELECT * FROM accuracy_draws WHERE id = ?1").bind(drawId).first<Record<string, unknown>>()
    : await db.prepare("SELECT * FROM accuracy_draws ORDER BY created_at DESC LIMIT 1").first<Record<string, unknown>>();
  if (!draw) return null;
  const cells = reveal ? await db.prepare(
    `SELECT c.ordinal, c.commodity_id, x.label AS commodity_label,
            c.store_location_id, l.display_name AS store_name,
            pv.name AS product_name, pv.size_text AS raw_size_text, pv.product_url, pv.taxonomy_path,
            o.purchase_price_minor, o.purchase_quantity, o.normalized_basis_unit,
            o.normalized_basis_qty_micros, o.per_unit_micros, o.raw_price_text, o.captured_at,
            v.verdict, v.verified_by, v.verified_at
       FROM accuracy_draw_cells c
       JOIN accuracy_draws d ON d.id = c.draw_id
       JOIN releases r ON r.id = d.release_id
       JOIN commodities x ON x.id = c.commodity_id AND x.configuration_id = r.configuration_id
       JOIN store_locations l ON l.id = c.store_location_id
       JOIN observations o ON o.id = c.observation_id
       JOIN product_versions pv ON pv.id = o.product_version_id
       LEFT JOIN operator_verdicts v ON v.draw_id = c.draw_id AND v.cell_ordinal = c.ordinal
      WHERE c.draw_id = ?1 ORDER BY c.ordinal`,
  ).bind(String(draw.id)).all() : await db.prepare(
    `SELECT c.ordinal, c.commodity_id, x.label AS commodity_label,
            c.store_location_id, l.display_name AS store_name,
            v.verdict, v.verified_by, v.verified_at
       FROM accuracy_draw_cells c
       JOIN accuracy_draws d ON d.id = c.draw_id
       JOIN releases r ON r.id = d.release_id
       JOIN commodities x ON x.id = c.commodity_id AND x.configuration_id = r.configuration_id
       JOIN store_locations l ON l.id = c.store_location_id
       LEFT JOIN operator_verdicts v ON v.draw_id = c.draw_id AND v.cell_ordinal = c.ordinal
      WHERE c.draw_id = ?1 ORDER BY l.display_name, c.ordinal`,
  ).bind(String(draw.id)).all();
  const stores: Record<string, Array<Record<string, unknown>>> = {};
  for (const raw of cells.results as Array<Record<string, unknown>>) {
    const store = String(raw.store_name);
    (stores[store] ??= []).push(raw);
  }
  const riskSamples = reveal ? await db.prepare(
    `SELECT ordinal, lane, risk_kind, risk_score, commodity_id, store_location_id, observation_id, recipe_slug,
            evidence_json, verdict, verified_by, verified_at, verdict_evidence_json
       FROM accuracy_risk_samples WHERE draw_id = ?1 ORDER BY ordinal`,
  ).bind(String(draw.id)).all() : await db.prepare(
    `SELECT lane, risk_kind, COUNT(*) AS sampled, COUNT(verdict) AS reviewed
       FROM accuracy_risk_samples WHERE draw_id = ?1 GROUP BY lane, risk_kind ORDER BY lane, risk_kind`,
  ).bind(String(draw.id)).all();
  return { ...draw, blind: !reveal, cells: cells.results, stores, riskSamples: riskSamples.results };
}

export async function recordAccuracyVerdicts(db: D1Database, input: AccuracyVerdicts, verifiedBy: string): Promise<{ recorded: number; completed: boolean }> {
  const draw = await db.prepare("SELECT status, sampled_count, created_at FROM accuracy_draws WHERE id = ?1").bind(input.drawId).first<{ status: string; sampled_count: number; created_at: string }>();
  if (!draw) throw new Error("accuracy draw not found");
  if (draw.status === "cancelled") throw new Error("accuracy draw is cancelled");
  const createdAt = Date.parse(draw.created_at.includes("T") ? draw.created_at : `${draw.created_at.replace(" ", "T")}Z`);
  const maximumVerifiedAt = Date.now() + 5 * 60 * 1000;
  for (const verdict of [...input.verdicts, ...input.riskVerdicts]) {
    const verifiedAt = Date.parse(verdict.verifiedAt);
    if (!Number.isFinite(verifiedAt) || verifiedAt < createdAt - 5 * 60 * 1000 || verifiedAt > maximumVerifiedAt) throw new Error("accuracy verdict timestamp is outside the draw window");
    const accessedAtText = verdict.evidence.accessedAt;
    if (accessedAtText !== null) {
      const accessedAt = Date.parse(accessedAtText);
      if (!Number.isFinite(accessedAt) || accessedAt < createdAt - 5 * 60 * 1000 || accessedAt > verifiedAt + 5 * 60 * 1000) throw new Error("accuracy evidence timestamp is outside the verification window");
    }
  }
  const statements: D1PreparedStatement[] = [];
  for (const verdict of input.verdicts) {
    const cell = await db.prepare(
      "SELECT ordinal FROM accuracy_draw_cells WHERE draw_id = ?1 AND ordinal = ?2",
    ).bind(input.drawId, verdict.ordinal).first();
    if (!cell) throw new Error(`accuracy cell ${verdict.ordinal} is not in the draw`);
    const verdictId = await deterministicId("verdict", input.drawId, String(verdict.ordinal));
    statements.push(db.prepare(
      `INSERT INTO operator_verdicts
         (id, draw_id, cell_ordinal, verdict, verified_by, verified_at, evidence_json)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
       ON CONFLICT(draw_id, cell_ordinal) DO UPDATE SET
         verdict = excluded.verdict, verified_by = excluded.verified_by,
         verified_at = excluded.verified_at, evidence_json = excluded.evidence_json`,
    ).bind(verdictId, input.drawId, verdict.ordinal, verdict.verdict, verifiedBy, verdict.verifiedAt, stableJson(verdict.evidence)));
  }
  for (let offset = 0; offset < statements.length; offset += 90) await db.batch(statements.slice(offset, offset + 90));
  for (const verdict of input.verdicts) await triageAccuracyVerdict(db, input.drawId, "uniform", verdict.ordinal, verdict.verdict, verdict.evidence);
  for (const verdict of input.riskVerdicts) {
    const sample = await db.prepare("SELECT ordinal FROM accuracy_risk_samples WHERE draw_id = ?1 AND ordinal = ?2").bind(input.drawId, verdict.ordinal).first();
    if (!sample) throw new Error(`accuracy risk sample ${verdict.ordinal} is not in the draw`);
    await db.prepare(
      `UPDATE accuracy_risk_samples SET verdict = ?3, verified_by = ?4, verified_at = ?5, verdict_evidence_json = ?6
        WHERE draw_id = ?1 AND ordinal = ?2`,
    ).bind(input.drawId, verdict.ordinal, verdict.verdict, verifiedBy, verdict.verifiedAt, stableJson(verdict.evidence)).run();
    await triageAccuracyVerdict(db, input.drawId, "risk", verdict.ordinal, verdict.verdict, verdict.evidence);
  }
  await reconcileCannotTellDigest(db, input.drawId);
  const count = (await db.prepare("SELECT COUNT(*) AS count FROM operator_verdicts WHERE draw_id = ?1").bind(input.drawId).first<{ count: number }>())?.count ?? 0;
  const riskCounts = await db.prepare("SELECT COUNT(*) AS sampled, COUNT(verdict) AS reviewed FROM accuracy_risk_samples WHERE draw_id = ?1").bind(input.drawId).first<{ sampled: number; reviewed: number }>();
  const completed = count === draw.sampled_count && (riskCounts?.reviewed ?? 0) === (riskCounts?.sampled ?? 0);
  if (completed) {
    await db.prepare("UPDATE accuracy_draws SET status = 'completed', completed_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(input.drawId).run();
  }
  return { recorded: input.verdicts.length + input.riskVerdicts.length, completed };
}

export async function markOverdueAccuracyDraws(db: D1Database): Promise<number> {
  const overdue = await db.prepare(
    "SELECT id, release_id, sampled_count FROM accuracy_draws WHERE status = 'open' AND due_at < CURRENT_TIMESTAMP",
  ).all<{ id: string; release_id: string; sampled_count: number }>();
  const statements: D1PreparedStatement[] = [];
  for (const draw of overdue.results) {
    const verdictCount = (await db.prepare("SELECT COUNT(*) AS count FROM operator_verdicts WHERE draw_id = ?1").bind(draw.id).first<{ count: number }>())?.count ?? 0;
    const triageId = await deterministicId("triage", "accuracy_gap", draw.id);
    statements.push(db.prepare("UPDATE accuracy_draws SET status = 'overdue' WHERE id = ?1").bind(draw.id));
    statements.push(db.prepare(
      `INSERT INTO triage_items
         (id, source_kind, source_ref, severity, status, title, evidence_json)
       VALUES (?1, 'accuracy_gap', ?2, 'hard', 'open', ?3, ?4)
       ON CONFLICT(source_ref) DO UPDATE SET title = excluded.title, evidence_json = excluded.evidence_json, updated_at = CURRENT_TIMESTAMP`,
    ).bind(triageId, draw.id, `Accuracy draw ${draw.id} missed its verdict window`, stableJson({ releaseId: draw.release_id, sampled: draw.sampled_count, verdictsRecorded: verdictCount })));
  }
  if (statements.length > 0) await db.batch(statements);
  return overdue.results.length;
}

export async function latestAccuracySummary(db: D1Database): Promise<AccuracySummary | null> {
  const row = await db.prepare(
    `SELECT d.id, d.release_id, d.status, d.sampled_count, d.due_at,
            COALESCE(SUM(CASE WHEN v.verdict = 'right' THEN 1 ELSE 0 END), 0) AS right_count,
            COALESCE(SUM(CASE WHEN v.verdict = 'wrong' THEN 1 ELSE 0 END), 0) AS wrong_count,
            COALESCE(SUM(CASE WHEN v.verdict = 'cannot_tell' THEN 1 ELSE 0 END), 0) AS cannot_count,
            COUNT(v.id) AS verdict_count
       FROM accuracy_draws d
       LEFT JOIN operator_verdicts v ON v.draw_id = d.id
      GROUP BY d.id ORDER BY d.created_at DESC LIMIT 1`,
  ).first<{ id: string; release_id: string; status: string; sampled_count: number; due_at: string; right_count: number; wrong_count: number; cannot_count: number; verdict_count: number }>();
  if (!row) return null;
  const determinate = row.right_count + row.wrong_count;
  return {
    drawId: row.id,
    releaseId: row.release_id,
    status: row.status,
    sampled: row.sampled_count,
    right: row.right_count,
    wrong: row.wrong_count,
    cannotTell: row.cannot_count,
    verdictsRecorded: row.verdict_count,
    accuracy: determinate > 0 ? row.right_count / determinate : null,
    wilson95: wilsonInterval(row.right_count, determinate),
    dueAt: row.due_at,
  };
}
