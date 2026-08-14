import { digestHex, stableJson } from "@thriftycrew/domain";

type MatchRunRow = {
  id: string;
  batch_id: string;
  configuration_id: string;
  input_hash: string;
  status: string;
  product_count: number;
  matched_count: number;
  unmatched_count: number;
  collision_count: number;
  aisle_rejected_count: number;
  detail_json: string;
};

export function matchRunCheckpointMaterial(prior: MatchRunRow, actual: { products: number; matched: number }) {
  if (prior.status !== "passed" || prior.collision_count !== 0) throw new Error("match-run checkpoint requires a collision-free passed prior run");
  if (actual.products !== prior.product_count || actual.matched !== prior.matched_count) {
    throw new Error(`prior match run is not currently integrity-true: ${stableJson({
      prior: { products: prior.product_count, matched: prior.matched_count }, actual,
    })}`);
  }
  if (prior.matched_count + prior.unmatched_count + prior.collision_count + prior.aisle_rejected_count !== prior.product_count) {
    throw new Error("prior match-run classifications are internally inconsistent");
  }
  return {
    schema: "match-run-integrity-checkpoint-v1",
    priorRunId: prior.id,
    priorInputHash: prior.input_hash,
    batchId: prior.batch_id,
    configurationId: prior.configuration_id,
    productCount: actual.products,
    matchedCount: actual.matched,
  };
}

export async function checkpointPassedMatchRun(db: D1Database, batchId: string) {
  const prior = await db.prepare(
    `SELECT run.id, run.batch_id, run.configuration_id, run.input_hash, run.status,
            run.product_count, run.matched_count, run.unmatched_count, run.collision_count,
            run.aisle_rejected_count, run.detail_json
       FROM match_runs run
       JOIN capture_batches batch ON batch.id = run.batch_id
       JOIN configuration_versions configuration ON configuration.id = run.configuration_id
      WHERE run.batch_id = ?1 AND run.status = 'passed' AND configuration.active = 1
        AND batch.status IN ('promoted','superseded')
        AND json_extract(run.detail_json, '$.integrityCheckpoint') IS NULL
      ORDER BY run.created_at DESC, run.id DESC LIMIT 1`,
  ).bind(batchId).first<MatchRunRow>();
  if (!prior) throw new Error("effective batch has no passed match run under the active configuration");
  const actual = await db.prepare(
    `SELECT COUNT(DISTINCT product.id) AS products,
            COUNT(DISTINCT CASE WHEN decision.product_id IS NOT NULL THEN product.id END) AS matched
       FROM capture_batch_observations member
       JOIN observations observation ON observation.id = member.observation_id
       JOIN product_versions version ON version.id = observation.product_version_id
       JOIN products product ON product.id = version.product_id
       LEFT JOIN match_decisions decision ON decision.product_id = product.id
        AND decision.configuration_id = ?2 AND decision.superseded_at IS NULL
      WHERE member.batch_id = ?1`,
  ).bind(batchId, prior.configuration_id).first<{ products: number; matched: number }>();
  if (!actual) throw new Error("match-run checkpoint could not recompute the effective batch counts");
  const material = matchRunCheckpointMaterial(prior, { products: Number(actual.products), matched: Number(actual.matched) });
  const inputHash = await digestHex(stableJson(material));
  const runId = `match_${inputHash.slice(0, 32)}`;
  const priorDetail = JSON.parse(prior.detail_json) as Record<string, unknown>;
  const detail = { ...priorDetail, integrityCheckpoint: material };
  const inserted = await db.prepare(
    `INSERT INTO match_runs
       (id, batch_id, configuration_id, input_hash, status, product_count, matched_count,
        unmatched_count, collision_count, aisle_rejected_count, detail_json)
     SELECT ?1, ?2, ?3, ?4, 'passed', ?5, ?6, ?7, 0, ?8, ?9
      WHERE (SELECT COUNT(DISTINCT product.id)
               FROM capture_batch_observations member
               JOIN observations observation ON observation.id = member.observation_id
               JOIN product_versions version ON version.id = observation.product_version_id
               JOIN products product ON product.id = version.product_id
              WHERE member.batch_id = ?2) = ?5
        AND (SELECT COUNT(DISTINCT CASE WHEN decision.product_id IS NOT NULL THEN product.id END)
               FROM capture_batch_observations member
               JOIN observations observation ON observation.id = member.observation_id
               JOIN product_versions version ON version.id = observation.product_version_id
               JOIN products product ON product.id = version.product_id
               LEFT JOIN match_decisions decision ON decision.product_id = product.id
                AND decision.configuration_id = ?3 AND decision.superseded_at IS NULL
              WHERE member.batch_id = ?2) = ?6
     ON CONFLICT(id) DO NOTHING`,
  ).bind(runId, batchId, prior.configuration_id, inputHash, prior.product_count, prior.matched_count,
    prior.unmatched_count, prior.aisle_rejected_count, stableJson(detail)).run();
  if ((inserted.meta.changes ?? 0) === 0) {
    const existing = await db.prepare(
      `SELECT batch_id, configuration_id, input_hash, status, product_count, matched_count,
              unmatched_count, collision_count, aisle_rejected_count
         FROM match_runs WHERE id = ?1`,
    ).bind(runId).first<Record<string, unknown>>();
    if (!existing) throw new Error("match-run checkpoint lost integrity before its immutable insert");
    const expected = [batchId, prior.configuration_id, inputHash, "passed", prior.product_count, prior.matched_count,
      prior.unmatched_count, 0, prior.aisle_rejected_count];
    const observed = [existing.batch_id, existing.configuration_id, existing.input_hash, existing.status,
      Number(existing.product_count), Number(existing.matched_count), Number(existing.unmatched_count),
      Number(existing.collision_count), Number(existing.aisle_rejected_count)];
    if (stableJson(observed) !== stableJson(expected)) throw new Error("deterministic match-run checkpoint identity conflicts with persisted data");
    return { runId, priorRunId: prior.id, batchId, configurationId: prior.configuration_id,
      productCount: prior.product_count, matchedCount: prior.matched_count, status: "passed" as const, idempotent: true };
  }
  return { runId, priorRunId: prior.id, batchId, configurationId: prior.configuration_id,
    productCount: prior.product_count, matchedCount: prior.matched_count, status: "passed" as const, idempotent: false };
}
