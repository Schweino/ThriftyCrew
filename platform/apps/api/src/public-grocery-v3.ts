export async function getPublicIngredientBySlug(db: D1Database, slug: string) {
  const row = await db.prepare(
    `SELECT version.public_version_id, version.snapshot_hash, version.snapshot_json
       FROM catalog_ingredient_versions definition
       JOIN public_ingredient_current current ON current.ingredient_id=definition.ingredient_id
       JOIN public_ingredient_versions version ON version.public_version_id=current.current_public_version_id
      WHERE definition.version_id=version.ingredient_definition_version_id AND definition.slug=?1`,
  ).bind(slug).first<{ public_version_id: string; snapshot_hash: string; snapshot_json: string }>();
  if (!row) return null;
  return { versionId: row.public_version_id, contentHash: row.snapshot_hash, ...JSON.parse(row.snapshot_json) as Record<string, unknown> };
}

export async function listPublicIngredients(db: D1Database) {
  const [manifest, rows] = await Promise.all([
    db.prepare("SELECT revision, content_hash, updated_at FROM public_ingredient_catalog_manifest WHERE singleton=1").first<{ revision: number; content_hash: string; updated_at: string }>(),
    db.prepare(
      `SELECT version.public_version_id, version.snapshot_hash, version.snapshot_json
         FROM public_ingredient_current current
         JOIN public_ingredient_versions version ON version.public_version_id=current.current_public_version_id
        WHERE version.state='current'
        ORDER BY json_extract(version.snapshot_json, '$.displayName') COLLATE NOCASE, version.ingredient_id`,
    ).all<{ public_version_id: string; snapshot_hash: string; snapshot_json: string }>(),
  ]);
  return { manifestRevision: Number(manifest?.revision ?? 0), manifestHash: manifest?.content_hash ?? "", updatedAt: manifest?.updated_at ?? null,
    ingredients: rows.results.map((row) => ({ versionId: row.public_version_id, contentHash: row.snapshot_hash, ...JSON.parse(row.snapshot_json) as Record<string, unknown> })) };
}

export function publicIngredientResponse(body: unknown, etag: string, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: {
    "content-type": "application/json; charset=utf-8", etag: `\"${etag}\"`,
    "cache-control": "public, max-age=10, s-maxage=10, stale-while-revalidate=30",
  } });
}
