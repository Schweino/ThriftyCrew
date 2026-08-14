import { OMAHA_STORE_LOCATION_IDS, publicIngredientSnapshotSchema, type PublicIngredientSnapshot } from "@thriftycrew/contracts";
import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";

export async function stageIncrementalIngredient(db: D1Database, input: { snapshot: PublicIngredientSnapshot; pricingJobId: string }) {
  const snapshot = publicIngredientSnapshotSchema.parse(input.snapshot);
  const stores = [...snapshot.stores].sort((a, b) => OMAHA_STORE_LOCATION_IDS.indexOf(a.storeLocationId) - OMAHA_STORE_LOCATION_IDS.indexOf(b.storeLocationId));
  const canonical = { ...snapshot, stores };
  const snapshotJson = stableJson(canonical);
  const snapshotHash = await digestHex(snapshotJson);
  const current = await db.prepare("SELECT current_public_version_id, pointer_generation FROM public_ingredient_current WHERE ingredient_id = ?1")
    .bind(snapshot.ingredientId).first<{ current_public_version_id: string; pointer_generation: number }>();
  const publicVersionId = await deterministicId("ingpub", snapshot.ingredientId, snapshot.definitionVersionId, snapshotHash);
  const rowsWithHashes = await Promise.all(stores.map(async (row) => ({ row, rowJson: stableJson(row), rowHash: await digestHex(stableJson(row)) })));
  const statements: D1PreparedStatement[] = [db.prepare(
    `INSERT OR IGNORE INTO public_ingredient_versions
       (public_version_id, ingredient_id, ingredient_definition_version_id, snapshot_json, snapshot_hash, state, previous_public_version_id)
     VALUES (?1, ?2, ?3, ?4, ?5, 'staged', ?6)`,
  ).bind(publicVersionId, snapshot.ingredientId, snapshot.definitionVersionId, snapshotJson, snapshotHash, current?.current_public_version_id ?? null)];
  rowsWithHashes.forEach(({ row, rowJson, rowHash }, ordinal) => {
    statements.push(db.prepare(
      `INSERT OR IGNORE INTO public_ingredient_store_rows
         (public_version_id, store_location_id, store_ordinal, terminal_status, row_json,
          producer_result_ref, verifier_result_ref, row_hash)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
    ).bind(publicVersionId, row.storeLocationId, ordinal, row.status, rowJson,
      row.producerEvidence.id, row.verifierEvidence.id, rowHash));
  });
  await db.batch(statements);
  return { publicVersionId, snapshotHash, previousPublicVersionId: current?.current_public_version_id ?? null,
    expectedPointerGeneration: Number(current?.pointer_generation ?? 0), pricingJobId: input.pricingJobId };
}

export async function previewIncrementalIngredient(db: D1Database, publicVersionId: string) {
  const version = await db.prepare("SELECT * FROM public_ingredient_versions WHERE public_version_id = ?1")
    .bind(publicVersionId).first<Record<string, unknown>>();
  if (!version) throw new Error("public ingredient version not found");
  const rows = await db.prepare("SELECT store_location_id, terminal_status, row_json, row_hash FROM public_ingredient_store_rows WHERE public_version_id = ?1 ORDER BY store_ordinal")
    .bind(publicVersionId).all<Record<string, unknown>>();
  if (rows.results.length !== 7) throw new Error("staged ingredient must contain exactly seven store rows");
  const parsed = publicIngredientSnapshotSchema.parse(JSON.parse(String(version.snapshot_json)));
  return { publicVersionId, ingredientId: version.ingredient_id, contentHash: version.snapshot_hash, snapshot: parsed,
    stores: rows.results.map((row) => ({ ...row, row: JSON.parse(String(row.row_json)) })) };
}

export async function compareAndSwapIngredientPointer(db: D1Database, input: {
  ingredientId: string; publicVersionId: string; expectedGeneration: number;
}) {
  if (input.expectedGeneration === 0) {
    const inserted = await db.prepare(
      `INSERT OR IGNORE INTO public_ingredient_current(ingredient_id, current_public_version_id, pointer_generation)
       VALUES (?1, ?2, 1)`,
    ).bind(input.ingredientId, input.publicVersionId).run();
    if ((inserted.meta.changes ?? 0) !== 1) throw new Error("ingredient pointer compare-and-swap conflict");
    return 1;
  }
  const moved = await db.prepare(
    `UPDATE public_ingredient_current SET current_public_version_id = ?2, pointer_generation = pointer_generation + 1,
       updated_at = CURRENT_TIMESTAMP WHERE ingredient_id = ?1 AND pointer_generation = ?3`,
  ).bind(input.ingredientId, input.publicVersionId, input.expectedGeneration).run();
  if ((moved.meta.changes ?? 0) !== 1) throw new Error("ingredient pointer compare-and-swap conflict");
  return input.expectedGeneration + 1;
}

export async function finalizeIncrementalIngredient(db: D1Database, input: {
  publicVersionId: string; pricingJobId: string; originProofs: Array<{ origin: string; url: string; expectedHash: string; observedHash: string; verifiedAt: string }>;
}) {
  if (input.originProofs.length !== 2 || new Set(input.originProofs.map((proof) => proof.origin)).size !== 2) throw new Error("exactly two distinct origin proofs are required");
  if (input.originProofs.some((proof) => proof.expectedHash !== proof.observedHash)) throw new Error("origin verification hash mismatch");
  const version = await db.prepare("SELECT ingredient_id, previous_public_version_id, snapshot_hash FROM public_ingredient_versions WHERE public_version_id = ?1")
    .bind(input.publicVersionId).first<{ ingredient_id: string; previous_public_version_id: string | null; snapshot_hash: string }>();
  if (!version) throw new Error("staged public ingredient is missing");
  const manifest = await db.prepare("SELECT revision, content_hash FROM public_ingredient_catalog_manifest WHERE singleton=1")
    .first<{ revision: number; content_hash: string }>();
  if (!manifest) throw new Error("public ingredient manifest is missing");
  const nextManifestHash = await digestHex(stableJson({ previousHash: manifest.content_hash, revision: Number(manifest.revision) + 1,
    ingredientId: version.ingredient_id, publicVersionId: input.publicVersionId, snapshotHash: version.snapshot_hash }));
  const statements: D1PreparedStatement[] = input.originProofs.map((proof) => db.prepare(
    `INSERT INTO public_ingredient_origin_proofs(public_version_id, origin, url, expected_hash, observed_hash, verified_at, status)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'verified')
     ON CONFLICT(public_version_id, origin) DO UPDATE SET observed_hash=excluded.observed_hash, verified_at=excluded.verified_at, status='verified'`,
  ).bind(input.publicVersionId, proof.origin, proof.url, proof.expectedHash, proof.observedHash, proof.verifiedAt));
  statements.push(db.prepare("UPDATE public_ingredient_versions SET state = 'current', published_at = COALESCE(published_at, CURRENT_TIMESTAMP) WHERE public_version_id = ?1").bind(input.publicVersionId));
  if (version.previous_public_version_id) statements.push(db.prepare("UPDATE public_ingredient_versions SET state = 'superseded' WHERE public_version_id = ?1 AND state = 'current'").bind(version.previous_public_version_id));
  statements.push(db.prepare("UPDATE ingredient_pricing_jobs SET operational_state='public_verified', state='public_verified', terminal_at=CURRENT_TIMESTAMP, last_progress_at=CURRENT_TIMESTAMP, updated_at=CURRENT_TIMESTAMP WHERE id=?1").bind(input.pricingJobId));
  statements.push(db.prepare("DELETE FROM ingredient_pricing_inbox WHERE pricing_job_id=?1").bind(input.pricingJobId));
  statements.push(db.prepare("UPDATE public_ingredient_catalog_manifest SET revision=revision+1, content_hash=?1, updated_at=CURRENT_TIMESTAMP WHERE singleton=1 AND revision=?2")
    .bind(nextManifestHash, manifest.revision));
  await db.batch(statements);
}

export async function rollbackIncrementalIngredientPointer(db: D1Database, input: { ingredientId: string; failedVersionId: string; expectedGeneration: number; previousVersionId: string | null }) {
  if (input.previousVersionId) {
    const rollback = await db.prepare(
      `UPDATE public_ingredient_current SET current_public_version_id=?2, pointer_generation=pointer_generation+1, updated_at=CURRENT_TIMESTAMP
       WHERE ingredient_id=?1 AND current_public_version_id=?3 AND pointer_generation=?4`,
    ).bind(input.ingredientId, input.previousVersionId, input.failedVersionId, input.expectedGeneration).run();
    if ((rollback.meta.changes ?? 0) !== 1) throw new Error("ingredient rollback pointer fence failed");
  } else {
    const rollback = await db.prepare("DELETE FROM public_ingredient_current WHERE ingredient_id=?1 AND current_public_version_id=?2 AND pointer_generation=?3")
      .bind(input.ingredientId, input.failedVersionId, input.expectedGeneration).run();
    if ((rollback.meta.changes ?? 0) !== 1) throw new Error("ingredient rollback pointer fence failed");
  }
  await db.prepare("UPDATE public_ingredient_versions SET state='rolled_back' WHERE public_version_id=?1").bind(input.failedVersionId).run();
}
