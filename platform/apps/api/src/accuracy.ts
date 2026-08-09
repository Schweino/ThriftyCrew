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
  for (let offset = 0; offset < statements.length; offset += 90) await db.batch(statements.slice(offset, offset + 90));
  return { drawId, sampled: sampled.length, idempotent: false };
}

export async function readAccuracyDraw(db: D1Database, drawId?: string): Promise<Record<string, unknown> | null> {
  const draw = drawId
    ? await db.prepare("SELECT * FROM accuracy_draws WHERE id = ?1").bind(drawId).first<Record<string, unknown>>()
    : await db.prepare("SELECT * FROM accuracy_draws ORDER BY created_at DESC LIMIT 1").first<Record<string, unknown>>();
  if (!draw) return null;
  const cells = await db.prepare(
    `SELECT c.ordinal, c.commodity_id, x.label AS commodity_label,
            c.store_location_id, l.display_name AS store_name, pv.product_url,
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
  ).bind(String(draw.id)).all();
  return { ...draw, cells: cells.results };
}

export async function recordAccuracyVerdicts(db: D1Database, input: AccuracyVerdicts, verifiedBy: string): Promise<{ recorded: number; completed: boolean }> {
  const draw = await db.prepare("SELECT status, sampled_count FROM accuracy_draws WHERE id = ?1").bind(input.drawId).first<{ status: string; sampled_count: number }>();
  if (!draw) throw new Error("accuracy draw not found");
  if (draw.status === "cancelled") throw new Error("accuracy draw is cancelled");
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
  const count = (await db.prepare("SELECT COUNT(*) AS count FROM operator_verdicts WHERE draw_id = ?1").bind(input.drawId).first<{ count: number }>())?.count ?? 0;
  const completed = count === draw.sampled_count;
  if (completed) {
    await db.prepare("UPDATE accuracy_draws SET status = 'completed', completed_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(input.drawId).run();
  }
  return { recorded: input.verdicts.length, completed };
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
