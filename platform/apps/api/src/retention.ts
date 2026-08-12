import type { WorkerEnv } from "./env";

export interface RetentionProtectionRow {
  observation_id: string;
  protections: string;
}

export interface RetentionProtectionSummary {
  protectedCount: number;
  byReason: Record<string, number>;
}

const protectionCte = `
WITH latest_promoted AS (
  SELECT id FROM (
    SELECT batch.id,
           ROW_NUMBER() OVER (PARTITION BY batch.source_id
             ORDER BY batch.captured_to DESC, batch.promoted_at DESC, batch.id DESC) AS ordinal
      FROM capture_batches batch
     WHERE batch.status = 'promoted'
  ) WHERE ordinal = 1
),
protected_observations(observation_id, reason, reference_id) AS (
  SELECT cell.observation_id, 'current-release-cell', current.release_id
    FROM current_releases current
    JOIN release_cells cell ON cell.release_id = current.release_id
   WHERE cell.observation_id IS NOT NULL
  UNION
  SELECT member.observation_id, 'active-release-input', input.release_id
    FROM release_input_batches input
    JOIN releases release ON release.id = input.release_id
    JOIN capture_observation_memberships member ON member.batch_id = input.batch_id
   WHERE release.state IN ('draft', 'validating', 'published')
  UNION
  SELECT member.observation_id, 'latest-promoted-batch', member.batch_id
    FROM capture_observation_memberships member
    JOIN latest_promoted latest ON latest.id = member.batch_id
  UNION
  SELECT member.observation_id, 'in-flight-batch', member.batch_id
    FROM capture_observation_memberships member
    JOIN capture_batches batch ON batch.id = member.batch_id
   WHERE batch.status IN ('open', 'sealed', 'validated')
  UNION
  SELECT cell.observation_id, 'accuracy-draw', cell.draw_id
    FROM accuracy_draw_cells cell
    JOIN accuracy_draws draw ON draw.id = cell.draw_id
  UNION
  SELECT sample.observation_id, 'accuracy-risk-sample', sample.draw_id
    FROM accuracy_risk_samples sample
    JOIN accuracy_draws draw ON draw.id = sample.draw_id
   WHERE sample.observation_id IS NOT NULL
  UNION
  SELECT member.observation_id, 'unresolved-triage-batch', batch.id
    FROM triage_items triage
    JOIN json_tree(triage.evidence_json) evidence ON evidence.type = 'text'
    JOIN capture_batches batch ON batch.id = CAST(evidence.value AS TEXT)
    JOIN capture_observation_memberships member ON member.batch_id = batch.id
   WHERE triage.status <> 'resolved'
)`;

export async function readRetentionProtections(db: D1Database, cutoffAt: string): Promise<RetentionProtectionRow[]> {
  const result = await db.prepare(`${protectionCte}
    SELECT observation_id, group_concat(protection) AS protections
      FROM (
        SELECT observation_id, reason || ':' || reference_id AS protection
          FROM protected_observations
         WHERE observation_id IN (SELECT id FROM observations WHERE captured_at < ?1)
         ORDER BY observation_id, reason, reference_id
      ) ordered
     GROUP BY observation_id
     ORDER BY observation_id`).bind(cutoffAt).all<RetentionProtectionRow>();
  return result.results;
}

export async function readRetentionCandidates(db: D1Database, cutoffAt: string, limit: number): Promise<string[]> {
  const result = await db.prepare(`${protectionCte}
    SELECT observation.id
      FROM observations observation
     WHERE observation.captured_at < ?1
       AND NOT EXISTS (SELECT 1 FROM protected_observations protected WHERE protected.observation_id = observation.id)
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
  const protectedRows = await readRetentionProtections(env.DB, cutoffAt);
  const protectedIds = new Set(protectedRows.map((row) => row.observation_id));
  const gained = observationIds.filter((id) => protectedIds.has(id));
  if (gained.length > 0) throw new Error(`archive candidates gained protected dependencies: ${gained.slice(0, 10).join(", ")}`);
}
