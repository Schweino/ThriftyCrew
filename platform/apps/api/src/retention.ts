import type { WorkerEnv } from "./env";

export interface RetentionProtectionRow {
  observation_id: string;
  protections: string;
}

export interface RetentionProtectionSummary {
  protectedCount: number;
  byReason: Record<string, number>;
}

const retentionCtes = `
WITH latest_promoted AS (
  SELECT id FROM (
    SELECT batch.id,
           ROW_NUMBER() OVER (PARTITION BY batch.source_id
             ORDER BY batch.captured_to DESC, batch.promoted_at DESC, batch.id DESC) AS ordinal
      FROM capture_batches batch
     WHERE batch.status = 'promoted'
  ) WHERE ordinal = 1
), unresolved_triage_batches AS (
  SELECT DISTINCT batch.id
    FROM triage_items triage
    JOIN json_tree(triage.evidence_json) evidence ON evidence.type = 'text'
    JOIN capture_batches batch ON batch.id = CAST(evidence.value AS TEXT)
   WHERE triage.status <> 'resolved'
)`;

const protectionPredicates = {
  "current-release-cell": `EXISTS (
    SELECT 1 FROM current_releases current JOIN release_cells cell ON cell.release_id = current.release_id
     WHERE cell.observation_id = observation.id)`,
  "active-release-input": `EXISTS (
    SELECT 1 FROM capture_observation_memberships member
    JOIN release_input_batches input ON input.batch_id = member.batch_id
    JOIN releases release ON release.id = input.release_id
    WHERE member.observation_id = observation.id AND release.state IN ('draft', 'validating', 'published'))`,
  "latest-promoted-batch": `EXISTS (
    SELECT 1 FROM capture_observation_memberships member JOIN latest_promoted latest ON latest.id = member.batch_id
     WHERE member.observation_id = observation.id)`,
  "in-flight-batch": `EXISTS (
    SELECT 1 FROM capture_observation_memberships member JOIN capture_batches batch ON batch.id = member.batch_id
     WHERE member.observation_id = observation.id AND batch.status IN ('open', 'sealed', 'validated'))`,
  "accuracy-draw": "EXISTS (SELECT 1 FROM accuracy_draw_cells cell WHERE cell.observation_id = observation.id)",
  "accuracy-risk-sample": "EXISTS (SELECT 1 FROM accuracy_risk_samples sample WHERE sample.observation_id = observation.id)",
  "unresolved-triage-batch": `EXISTS (
    SELECT 1 FROM capture_observation_memberships member JOIN unresolved_triage_batches triage ON triage.id = member.batch_id
     WHERE member.observation_id = observation.id)`,
} as const;

const protectedPredicate = Object.values(protectionPredicates).map((predicate) => `(${predicate})`).join(" OR ");

export async function readRetentionProtectionSummary(db: D1Database, cutoffAt: string): Promise<RetentionProtectionSummary> {
  const reasonEntries = Object.entries(protectionPredicates);
  const columns = [
    ...reasonEntries.map(([reason, predicate], index) => `(SELECT COUNT(*) FROM observations observation WHERE observation.captured_at < ?1 AND ${predicate}) AS reason_${index}`),
    `(SELECT COUNT(*) FROM observations observation WHERE observation.captured_at < ?1 AND (${protectedPredicate})) AS protected_total`,
  ];
  const row = await db.prepare(`${retentionCtes} SELECT ${columns.join(", ")}`).bind(cutoffAt).first<Record<string, number>>();
  const byReason = Object.fromEntries(reasonEntries.map(([reason], index) => [reason, row?.[`reason_${index}`] ?? 0]));
  return { protectedCount: row?.protected_total ?? 0, byReason };
}

export async function readRetentionCandidates(db: D1Database, cutoffAt: string, limit: number): Promise<string[]> {
  const result = await db.prepare(`${retentionCtes}
    SELECT observation.id
      FROM observations observation
     WHERE observation.captured_at < ?1
       AND NOT (${protectedPredicate})
       AND NOT EXISTS (SELECT 1 FROM archive_manifest_observations archived WHERE archived.observation_id = observation.id)
     ORDER BY observation.captured_at, observation.id
     LIMIT ?2`).bind(cutoffAt, limit).all<{ id: string }>();
  return result.results.map((row) => row.id);
}

export function summarizeRetentionProtections(rows: readonly RetentionProtectionRow[]): RetentionProtectionSummary {
  const byReason: Record<string, number> = {};
  for (const row of rows) {
    const reasons = new Set(row.protections.split(",").map((item) => item.split(":", 1)[0]!).filter(Boolean));
    for (const reason of reasons) byReason[reason] = (byReason[reason] ?? 0) + 1;
  }
  return { protectedCount: rows.length, byReason: Object.fromEntries(Object.entries(byReason).sort(([left], [right]) => left.localeCompare(right))) };
}

export async function assertRetentionCandidatesStillUnprotected(env: WorkerEnv, cutoffAt: string, observationIds: readonly string[]): Promise<void> {
  if (observationIds.length === 0) return;
  const gained = await env.DB.prepare(`${retentionCtes}
    SELECT observation.id
      FROM observations observation JOIN json_each(?2) candidate ON CAST(candidate.value AS TEXT) = observation.id
     WHERE observation.captured_at < ?1 AND (${protectedPredicate})
     ORDER BY observation.id LIMIT 10`).bind(cutoffAt, JSON.stringify(observationIds)).all<{ id: string }>();
  if (gained.results.length > 0) throw new Error(`archive candidates gained protected dependencies: ${gained.results.map((row) => row.id).join(", ")}`);
}
