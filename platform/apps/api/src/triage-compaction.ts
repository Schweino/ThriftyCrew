import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";
import type { WorkerEnv } from "./env";

interface CompactionRow {
  result_id: string;
  guard_id: string;
  release_id: string;
  guard_status: string;
  eligible_count: number;
  examined_count: number;
  finding_count: number;
  guard_detail_json: string;
  guard_created_at: string;
  release_state: string;
  release_published_at: string | null;
  finding_id: string;
  finding_key: string;
  finding_message: string;
  finding_evidence_json: string;
  triage_id: string | null;
  triage_severity: string | null;
  triage_status: string | null;
  triage_title: string | null;
  triage_evidence_json: string | null;
  triage_plan_ref: string | null;
  triage_resolution_json: string | null;
  triage_created_at: string | null;
  triage_updated_at: string | null;
  triage_resolved_at: string | null;
}

export interface HistoricalTriageArchive {
  version: 1;
  kind: "historical-release-triage-archive";
  createdAt: string;
  currentReleaseId: string;
  results: Array<{
    id: string;
    guardId: string;
    releaseId: string;
    status: string;
    eligibleCount: number;
    examinedCount: number;
    findingCount: number;
    detailJson: string;
    createdAt: string;
    releaseState: string;
    releasePublishedAt: string | null;
    findings: Array<{
      id: string;
      key: string;
      message: string;
      evidenceJson: string;
      triage: null | {
        id: string; severity: string; status: string; title: string; evidenceJson: string;
        planRef: string | null; resolutionJson: string; createdAt: string; updatedAt: string; resolvedAt: string | null;
      };
    }>;
  }>;
}

export function buildHistoricalTriageArchive(currentReleaseId: string, createdAt: string, rows: readonly CompactionRow[]): HistoricalTriageArchive {
  const results = new Map<string, HistoricalTriageArchive["results"][number]>();
  for (const row of rows) {
    let result = results.get(row.result_id);
    if (!result) {
      result = {
        id: row.result_id, guardId: row.guard_id, releaseId: row.release_id, status: row.guard_status,
        eligibleCount: row.eligible_count, examinedCount: row.examined_count, findingCount: row.finding_count,
        detailJson: row.guard_detail_json, createdAt: row.guard_created_at, releaseState: row.release_state,
        releasePublishedAt: row.release_published_at, findings: [],
      };
      results.set(row.result_id, result);
    }
    result.findings.push({
      id: row.finding_id, key: row.finding_key, message: row.finding_message, evidenceJson: row.finding_evidence_json,
      triage: row.triage_id ? {
        id: row.triage_id, severity: row.triage_severity!, status: row.triage_status!, title: row.triage_title!,
        evidenceJson: row.triage_evidence_json!, planRef: row.triage_plan_ref,
        resolutionJson: row.triage_resolution_json!, createdAt: row.triage_created_at!, updatedAt: row.triage_updated_at!,
        resolvedAt: row.triage_resolved_at,
      } : null,
    });
  }
  return { version: 1, kind: "historical-release-triage-archive", createdAt, currentReleaseId, results: [...results.values()] };
}

async function compactionRows(env: WorkerEnv, limit: number): Promise<{ currentReleaseId: string; rows: CompactionRow[] }> {
  const current = await env.DB.prepare("SELECT release_id FROM current_releases WHERE market_id = 'omaha'").first<{ release_id: string }>();
  if (!current) throw new Error("No current Omaha release");
  const rows = await env.DB.prepare(
    `WITH eligible_results AS (
       SELECT result.id, COALESCE(release.published_at, release.created_at) AS release_time
         FROM guard_results recovered
         JOIN guard_results result ON result.guard_id = recovered.guard_id AND result.release_id <> recovered.release_id
         JOIN releases release ON release.id = result.release_id
         JOIN guard_findings finding ON finding.result_id = result.id
         LEFT JOIN triage_items triage ON triage.source_kind = 'guard_finding' AND triage.source_ref = finding.id
         LEFT JOIN agent_work_items work ON work.source_kind = 'triage-item' AND work.source_ref = triage.id AND work.state = 'leased'
        WHERE recovered.release_id = ?1 AND recovered.status = 'pass'
        GROUP BY result.id, release_time
       HAVING MAX(CASE WHEN triage.status IN ('planned', 'needs_operator') THEN 1 ELSE 0 END) = 0
          AND COUNT(work.id) = 0
        ORDER BY release_time, result.id
        LIMIT ?2
     )
     SELECT result.id AS result_id, result.guard_id, result.release_id, result.status AS guard_status,
            result.eligible_count, result.examined_count, result.finding_count, result.detail_json AS guard_detail_json,
            result.created_at AS guard_created_at, release.state AS release_state, release.published_at AS release_published_at,
            finding.id AS finding_id, finding.finding_key, finding.message AS finding_message,
            finding.evidence_json AS finding_evidence_json, triage.id AS triage_id, triage.severity AS triage_severity,
            triage.status AS triage_status, triage.title AS triage_title, triage.evidence_json AS triage_evidence_json,
            triage.plan_ref AS triage_plan_ref, triage.resolution_json AS triage_resolution_json,
            triage.created_at AS triage_created_at, triage.updated_at AS triage_updated_at,
            triage.resolved_at AS triage_resolved_at
       FROM eligible_results eligible
       JOIN guard_results result ON result.id = eligible.id
       JOIN releases release ON release.id = result.release_id
       JOIN guard_findings finding ON finding.result_id = result.id
       LEFT JOIN triage_items triage ON triage.source_kind = 'guard_finding' AND triage.source_ref = finding.id
      ORDER BY result.release_id, result.guard_id, finding.id`,
  ).bind(current.release_id, limit).all<CompactionRow>();
  return { currentReleaseId: current.release_id, rows: rows.results };
}

export async function compactHistoricalTriage(env: WorkerEnv, options: { execute: boolean; limit: number }) {
  const selected = await compactionRows(env, options.limit);
  if (selected.rows.length === 0) return { ok: true, dryRun: !options.execute, currentReleaseId: selected.currentReleaseId, resultCount: 0, findingCount: 0, triageCount: 0 };
  const createdAt = new Date().toISOString();
  const archive = buildHistoricalTriageArchive(selected.currentReleaseId, createdAt, selected.rows);
  const resultIds = archive.results.map((result) => result.id);
  const guardIds = [...new Set(archive.results.map((result) => result.guardId))].sort();
  const triageCount = selected.rows.filter((row) => row.triage_id).length;
  const summary = {
    currentReleaseId: selected.currentReleaseId, resultCount: archive.results.length,
    findingCount: selected.rows.length, triageCount, guardIds,
  };
  if (!options.execute) return { ok: true, dryRun: true, ...summary };

  const serialized = stableJson(archive);
  const bytes = new TextEncoder().encode(serialized);
  const contentHash = await digestHex(bytes);
  const archiveId = await deterministicId("triage-archive", selected.currentReleaseId, ...resultIds);
  const date = createdAt.slice(0, 10).replaceAll("-", "/");
  const objectKey = `triage-archives/schema=1/date=${date}/prefix=${contentHash.slice(0, 2)}/${contentHash}.json`;
  await env.ARCHIVE.put(objectKey, bytes, { customMetadata: {
    sha256: contentHash, schema: "historical-release-triage-v1", currentReleaseId: selected.currentReleaseId,
  } });
  const uploaded = await env.ARCHIVE.get(objectKey);
  if (!uploaded || uploaded.size !== bytes.byteLength || await digestHex(new Uint8Array(await uploaded.arrayBuffer())) !== contentHash) {
    throw new Error("Historical triage archive failed read-after-write verification");
  }

  const placeholders = resultIds.map((_, index) => `?${index + 10}`).join(",");
  const guardPlaceholders = guardIds.map((_, index) => `?${resultIds.length + index + 10}`).join(",");
  const sharedBindings: unknown[] = [archiveId, selected.currentReleaseId, objectKey, contentHash, bytes.byteLength,
    archive.results.length, selected.rows.length, triageCount, createdAt, ...resultIds, ...guardIds];
  const gate = `EXISTS (SELECT 1 FROM current_releases current WHERE current.market_id = 'omaha' AND current.release_id = ?2)
    AND NOT EXISTS (
      SELECT 1 FROM guard_findings finding JOIN triage_items triage ON triage.source_ref = finding.id
       WHERE finding.result_id IN (${placeholders}) AND triage.status IN ('planned', 'needs_operator')
    )
    AND NOT EXISTS (
      SELECT 1 FROM guard_findings finding JOIN triage_items triage ON triage.source_ref = finding.id
       JOIN agent_work_items work ON work.source_kind = 'triage-item' AND work.source_ref = triage.id
       WHERE finding.result_id IN (${placeholders}) AND work.state = 'leased'
    )
    AND (SELECT COUNT(DISTINCT guard_id) FROM guard_results
          WHERE release_id = ?2 AND status = 'pass' AND guard_id IN (${guardPlaceholders})) = ${guardIds.length}`;
  const inserted = env.DB.prepare(
    `INSERT INTO triage_archives
       (id, current_release_id, object_key, content_hash, byte_length, result_count, finding_count, triage_count, schema_version, completed_at)
     SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1, ?9 WHERE ${gate}
     ON CONFLICT(id) DO NOTHING`,
  ).bind(...sharedBindings);
  const deleteBindings = [archiveId, ...resultIds];
  const deletePlaceholders = resultIds.map((_, index) => `?${index + 2}`).join(",");
  await env.DB.batch([
    inserted,
    env.DB.prepare(
      `UPDATE agent_work_items SET state = 'cancelled', updated_at = CURRENT_TIMESTAMP
        WHERE source_kind = 'triage-item' AND state IN ('queued', 'retryable')
          AND source_ref IN (SELECT triage.id FROM triage_items triage JOIN guard_findings finding ON finding.id = triage.source_ref
                              WHERE finding.result_id IN (${deletePlaceholders}))
          AND EXISTS (SELECT 1 FROM triage_archives WHERE id = ?1)`,
    ).bind(...deleteBindings),
    env.DB.prepare(
      `DELETE FROM triage_items WHERE source_kind = 'guard_finding'
        AND source_ref IN (SELECT id FROM guard_findings WHERE result_id IN (${deletePlaceholders}))
        AND EXISTS (SELECT 1 FROM triage_archives WHERE id = ?1)`,
    ).bind(...deleteBindings),
    env.DB.prepare(
      `DELETE FROM guard_findings WHERE result_id IN (${deletePlaceholders})
        AND EXISTS (SELECT 1 FROM triage_archives WHERE id = ?1)`,
    ).bind(...deleteBindings),
    env.DB.prepare(
      `DELETE FROM guard_results WHERE id IN (${deletePlaceholders})
        AND EXISTS (SELECT 1 FROM triage_archives WHERE id = ?1)`,
    ).bind(...deleteBindings),
  ]);
  const recorded = await env.DB.prepare("SELECT id FROM triage_archives WHERE id = ?1").bind(archiveId).first();
  if (!recorded) {
    await env.ARCHIVE.delete(objectKey);
    throw new Error("Historical triage state changed during compaction; retry from a fresh plan");
  }
  const remaining = await env.DB.prepare(`SELECT COUNT(*) AS count FROM guard_results WHERE id IN (${resultIds.map((_, index) => `?${index + 1}`).join(",")})`)
    .bind(...resultIds).first<{ count: number }>();
  if ((remaining?.count ?? 0) !== 0) throw new Error("Historical triage compaction did not remove every archived result");
  return { ok: true, dryRun: false, archiveId, objectKey, contentHash, byteLength: bytes.byteLength, ...summary };
}
