import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";
import type { WorkerEnv } from "./env";

export type ManagedBucket = "archive" | "evidence";
export interface ManagedObject {
  bucket: ManagedBucket;
  key: string;
  size: number;
  uploaded: string;
  contentHash?: string | null;
}

const managedPrefixes: Record<ManagedBucket, string[]> = {
  archive: ["release-nodes/", "release-manifests/", "observations/", "configurations/", "engine-snapshots/", "triage-archives/"],
  evidence: ["recipe-bundles/v2/", "recipe-cost-details/", "recipe-cost-detail-archives/", "releases/"],
};

function rootKey(bucket: ManagedBucket, key: string): string {
  return `${bucket}\u0000${key}`;
}

function releaseNodeKey(kind: string, contentHash: string): string {
  return `release-nodes/schema=1/kind=${kind}/prefix=${contentHash.slice(0, 2)}/${contentHash}.json`;
}

interface RecoveryManifestReferenceSet {
  releaseRoots: Array<{ release_id: string; root_hash: string; object_key: string }>;
  observationLake?: { partitions?: Array<{ object_key: string }> };
  immutableObjects?: Array<{ bucket: ManagedBucket; object_key: string }>;
}

export function recoveryManifestDirectReferences(manifest: RecoveryManifestReferenceSet): Array<{ bucket: ManagedBucket; key: string }> {
  if (!Array.isArray(manifest.releaseRoots)) throw new Error("backup recovery manifest release roots are invalid during garbage collection");
  const references: Array<{ bucket: ManagedBucket; key: string }> = [];
  for (const partition of manifest.observationLake?.partitions ?? []) references.push({ bucket: "archive", key: partition.object_key });
  for (const object of manifest.immutableObjects ?? []) {
    if (object.bucket !== "archive" && object.bucket !== "evidence") throw new Error("backup recovery manifest bucket is invalid during garbage collection");
    references.push({ bucket: object.bucket, key: object.object_key });
  }
  return references;
}

export function selectGarbageObjects(objects: readonly ManagedObject[], reachable: ReadonlySet<string>, graceBefore: string, limit: number): ManagedObject[] {
  const cutoff = Date.parse(graceBefore);
  return objects.filter((object) => Date.parse(object.uploaded) < cutoff && !reachable.has(rootKey(object.bucket, object.key)))
    .sort((left, right) => left.uploaded.localeCompare(right.uploaded) || left.bucket.localeCompare(right.bucket) || left.key.localeCompare(right.key))
    .slice(0, limit);
}

async function listPrefix(bucket: R2Bucket, bucketName: ManagedBucket, prefix: string): Promise<ManagedObject[]> {
  const objects: ManagedObject[] = [];
  let cursor: string | undefined;
  do {
    const listed = await bucket.list({ prefix, limit: 1000, ...(cursor ? { cursor } : {}) });
    objects.push(...listed.objects.map((object) => ({
      bucket: bucketName, key: object.key, size: object.size, uploaded: object.uploaded.toISOString(),
    })));
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
  return objects;
}

export async function listManagedObjects(env: Pick<WorkerEnv, "ARCHIVE" | "EVIDENCE">): Promise<ManagedObject[]> {
  const groups = await Promise.all([
    ...managedPrefixes.archive.map((prefix) => listPrefix(env.ARCHIVE, "archive", prefix)),
    ...managedPrefixes.evidence.map((prefix) => listPrefix(env.EVIDENCE, "evidence", prefix)),
  ]);
  return groups.flat();
}

export async function collectReachableObjectKeys(env: Pick<WorkerEnv, "DB" | "ARCHIVE" | "BACKUPS">): Promise<Set<string>> {
  const reachable = new Set<string>();
  const [graphs, archiveRows, evidenceRows, backupRows] = await Promise.all([
    env.DB.prepare("SELECT release_id, root_hash, object_key FROM release_graphs ORDER BY release_id")
      .all<{ release_id: string; root_hash: string; object_key: string }>(),
    env.DB.prepare(
      `SELECT object.object_key FROM observation_partitions partition
         JOIN object_store_objects object ON object.content_hash = partition.content_hash
       UNION SELECT object_key FROM archive_manifests WHERE status = 'verified' OR completed_at IS NOT NULL
       UNION SELECT object_key FROM configuration_archives WHERE status = 'verified'
       UNION SELECT object_key FROM triage_archives
       UNION SELECT shard.object_key
         FROM engine_snapshot_shards shard
        WHERE shard.status = 'verified'
          AND shard.configuration_id = (SELECT id FROM configuration_versions WHERE active = 1)
          AND shard.batch_id IN (
            SELECT id FROM (
              SELECT batch.id, ROW_NUMBER() OVER (
                PARTITION BY batch.source_id ORDER BY batch.captured_to DESC, batch.promoted_at DESC, batch.id DESC
              ) AS ordinal
                FROM capture_batches batch WHERE batch.status = 'promoted'
            ) WHERE ordinal = 1
          )`,
    ).all<{ object_key: string }>(),
    env.DB.prepare(
      `SELECT object_key FROM release_payloads WHERE object_key IS NOT NULL
       UNION SELECT object_key FROM release_recipe_payloads
       UNION SELECT object_key FROM recipe_cost_detail_objects`,
    ).all<{ object_key: string }>(),
    env.DB.prepare(
      `SELECT id, object_key, content_hash, byte_length FROM lake_backup_manifests
        WHERE status = 'completed' AND replica_verified = 1 AND created_at >= datetime('now', '-30 days')
        ORDER BY created_at DESC`,
    ).all<{ id: string; object_key: string; content_hash: string; byte_length: number }>(),
  ]);
  for (const row of archiveRows.results) reachable.add(rootKey("archive", row.object_key));
  for (const row of evidenceRows.results) reachable.add(rootKey("evidence", row.object_key));
  const addReleaseGraph = async (graph: { release_id: string; root_hash: string; object_key: string }) => {
    if (reachable.has(rootKey("archive", graph.object_key))) return;
    reachable.add(rootKey("archive", graph.object_key));
    const object = await env.ARCHIVE.get(graph.object_key);
    if (!object) throw new Error(`release graph root is missing during garbage collection: ${graph.release_id}`);
    const bytes = new Uint8Array(await object.arrayBuffer());
    if (await digestHex(bytes) !== graph.root_hash) throw new Error(`release graph root hash failed during garbage collection: ${graph.release_id}`);
    const manifest = JSON.parse(new TextDecoder().decode(bytes)) as { nodes?: Array<{ kind?: unknown; contentHash?: unknown }> };
    if (!Array.isArray(manifest.nodes)) throw new Error(`release graph root is invalid during garbage collection: ${graph.release_id}`);
    for (const node of manifest.nodes) {
      const kind = String(node.kind ?? "");
      const contentHash = String(node.contentHash ?? "");
      if (!kind || !/^[a-f0-9]{64}$/.test(contentHash)) throw new Error(`release graph node identity is invalid during garbage collection: ${graph.release_id}`);
      reachable.add(rootKey("archive", releaseNodeKey(kind, contentHash)));
    }
  };
  for (const graph of graphs.results) await addReleaseGraph(graph);
  for (const backup of backupRows.results) {
    const object = await env.BACKUPS.get(backup.object_key);
    if (!object || object.size !== backup.byte_length) throw new Error(`retained backup recovery manifest is missing during garbage collection: ${backup.id}`);
    const bytes = new Uint8Array(await object.arrayBuffer());
    if (await digestHex(bytes) !== backup.content_hash) throw new Error(`retained backup recovery manifest hash failed during garbage collection: ${backup.id}`);
    const manifest = JSON.parse(new TextDecoder().decode(bytes)) as RecoveryManifestReferenceSet;
    for (const reference of recoveryManifestDirectReferences(manifest)) reachable.add(rootKey(reference.bucket, reference.key));
    for (const graph of manifest.releaseRoots) await addReleaseGraph(graph);
  }
  return reachable;
}

export async function planR2GarbageCollection(env: WorkerEnv, options: { graceDays: number; maximumObjects: number; execute: boolean }) {
  const now = new Date();
  const graceBefore = new Date(now.getTime() - options.graceDays * 24 * 60 * 60 * 1000).toISOString();
  const [reachable, objects] = await Promise.all([collectReachableObjectKeys(env), listManagedObjects(env)]);
  const candidates = selectGarbageObjects(objects, reachable, graceBefore, options.maximumObjects);
  const verifiedCandidates = await Promise.all(candidates.map(async (candidate) => {
    const bucket = candidate.bucket === "archive" ? env.ARCHIVE : env.EVIDENCE;
    const head = await bucket.head(candidate.key);
    if (!head || head.size !== candidate.size) throw new Error(`R2 garbage collection candidate changed during planning: ${candidate.key}`);
    return { ...candidate, contentHash: head.customMetadata?.sha256 ?? null };
  }));
  const roots = [...reachable].sort();
  const rootSetHash = await digestHex(stableJson(roots));
  const runId = await deterministicId("r2-gc", now.toISOString(), rootSetHash, ...verifiedCandidates.map((item) => `${item.bucket}:${item.key}`));
  const result = {
    runId, graceBefore, scannedObjects: objects.length, reachableObjects: reachable.size,
    candidateObjects: verifiedCandidates.length, candidateBytes: verifiedCandidates.reduce((sum, item) => sum + item.size, 0), rootSetHash,
  };
  if (!options.execute) return { ok: true, dryRun: true, ...result };
  const statements: D1PreparedStatement[] = [env.DB.prepare(
    `INSERT INTO r2_gc_runs
       (id, status, grace_before, scanned_objects, reachable_objects, candidate_objects, candidate_bytes, root_set_hash, detail_json)
     VALUES (?1, 'planned', ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
  ).bind(runId, graceBefore, objects.length, reachable.size, candidates.length, result.candidateBytes, rootSetHash,
    stableJson({ policy: "reference-aware-v1", quarantineHours: 24, managedPrefixes }))];
  for (const candidate of verifiedCandidates) statements.push(env.DB.prepare(
    `INSERT INTO r2_gc_candidates
       (run_id, bucket, object_key, content_hash, byte_length, last_modified, reason)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'unreferenced-after-grace')`,
  ).bind(runId, candidate.bucket, candidate.key, candidate.contentHash, candidate.size, candidate.uploaded));
  for (let offset = 0; offset < statements.length; offset += 80) await env.DB.batch(statements.slice(offset, offset + 80));
  return { ok: true, dryRun: false, ...result, quarantineHours: 24 };
}

export async function sweepR2GarbageCollection(env: WorkerEnv, runId: string, execute: boolean) {
  const run = await env.DB.prepare(
    "SELECT status, created_at FROM r2_gc_runs WHERE id = ?1",
  ).bind(runId).first<{ status: string; created_at: string }>();
  if (!run) throw new Error("R2 garbage collection run not found");
  if (run.status === "completed") return { ok: true, runId, status: "completed", idempotent: true };
  if (run.status !== "planned") throw new Error(`R2 garbage collection run cannot sweep from ${run.status}`);
  const eligibleAt = Date.parse(`${run.created_at.replace(" ", "T")}Z`) + 24 * 60 * 60 * 1000;
  if (Date.now() < eligibleAt) throw new Error(`R2 garbage collection quarantine remains active until ${new Date(eligibleAt).toISOString()}`);
  const candidates = await env.DB.prepare(
    "SELECT bucket, object_key, content_hash, byte_length FROM r2_gc_candidates WHERE run_id = ?1 AND status = 'quarantined' ORDER BY bucket, object_key",
  ).bind(runId).all<{ bucket: ManagedBucket; object_key: string; content_hash: string | null; byte_length: number }>();
  const reachable = await collectReachableObjectKeys(env);
  const deletable = candidates.results.filter((item) => !reachable.has(rootKey(item.bucket, item.object_key)));
  const retained = candidates.results.filter((item) => reachable.has(rootKey(item.bucket, item.object_key)));
  if (!execute) return { ok: true, dryRun: true, runId, candidates: candidates.results.length, deletable: deletable.length, retained: retained.length };
  await env.DB.prepare("UPDATE r2_gc_runs SET status = 'sweeping' WHERE id = ?1 AND status = 'planned'").bind(runId).run();
  let deletedBytes = 0;
  const outcomes: Array<{ bucket: ManagedBucket; object_key: string; status: "deleted" | "missing" }> = [];
  for (let offset = 0; offset < deletable.length; offset += 40) {
    const chunk = deletable.slice(offset, offset + 40);
    const chunkOutcomes = await Promise.all(chunk.map(async (item) => {
      const bucket = item.bucket === "archive" ? env.ARCHIVE : env.EVIDENCE;
      const existing = await bucket.head(item.object_key);
      if (!existing) return { bucket: item.bucket, object_key: item.object_key, status: "missing" as const };
      if (existing.size !== item.byte_length) throw new Error(`R2 garbage collection object changed size during quarantine: ${item.object_key}`);
      if (item.content_hash && existing.customMetadata?.sha256 !== item.content_hash) throw new Error(`R2 garbage collection object changed hash during quarantine: ${item.object_key}`);
      await bucket.delete(item.object_key);
      if (await bucket.head(item.object_key)) throw new Error(`R2 garbage collection deletion did not converge: ${item.object_key}`);
      deletedBytes += item.byte_length;
      return { bucket: item.bucket, object_key: item.object_key, status: "deleted" as const };
    }));
    outcomes.push(...chunkOutcomes);
  }
  const finishedAt = new Date().toISOString();
  const statements: D1PreparedStatement[] = [
    ...retained.map((item) => env.DB.prepare(
      "UPDATE r2_gc_candidates SET status = 'retained', swept_at = ?4 WHERE run_id = ?1 AND bucket = ?2 AND object_key = ?3",
    ).bind(runId, item.bucket, item.object_key, finishedAt)),
    ...outcomes.map((item) => env.DB.prepare(
      "UPDATE r2_gc_candidates SET status = ?4, swept_at = ?5 WHERE run_id = ?1 AND bucket = ?2 AND object_key = ?3",
    ).bind(runId, item.bucket, item.object_key, item.status, finishedAt)),
    env.DB.prepare(
      `UPDATE r2_gc_runs SET status = 'completed', deleted_objects = ?2, deleted_bytes = ?3,
              completed_at = ?4, detail_json = json_set(detail_json, '$.retainedAtSweep', ?5)
        WHERE id = ?1`,
    ).bind(runId, outcomes.filter((item) => item.status === "deleted").length, deletedBytes, finishedAt, retained.length),
  ];
  for (const item of outcomes) {
    if (item.bucket === "archive" && item.object_key.startsWith("engine-snapshots/")) statements.push(env.DB.prepare(
      `UPDATE engine_snapshot_shards SET status = 'collected', collected_at = ?2
        WHERE object_key = ?1 AND status = 'verified'`,
    ).bind(item.object_key, finishedAt));
  }
  for (let offset = 0; offset < statements.length; offset += 80) await env.DB.batch(statements.slice(offset, offset + 80));
  return { ok: true, dryRun: false, runId, status: "completed", deleted: outcomes.filter((item) => item.status === "deleted").length,
    missing: outcomes.filter((item) => item.status === "missing").length, retained: retained.length, deletedBytes };
}
