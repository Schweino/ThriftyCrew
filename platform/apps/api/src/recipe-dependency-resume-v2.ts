import { deterministicId } from "@thriftycrew/domain";

export async function resumeRecipesForPublishedIngredient(db: D1Database, input: {
  ingredientId: string; definitionVersionId: string; publicVersionId: string;
}) {
  const unresolved = await db.prepare(
    `SELECT recipe_candidate_id, source_occurrence_id FROM recipe_ingredient_dependencies_v2
      WHERE ingredient_id=?1 AND status='unresolved' AND
        (required_definition_version_id IS NULL OR required_definition_version_id=?2)
      ORDER BY recipe_candidate_id, source_occurrence_id`,
  ).bind(input.ingredientId, input.definitionVersionId).all<{ recipe_candidate_id: string; source_occurrence_id: string }>();
  if (unresolved.results.length === 0) return { satisfied: 0, readyRecipeIds: [] as string[] };
  await db.batch(unresolved.results.map((row) => db.prepare(
    `UPDATE recipe_ingredient_dependencies_v2 SET status='resolved', resolved_public_version_id=?3, resolved_at=CURRENT_TIMESTAMP
     WHERE recipe_candidate_id=?1 AND source_occurrence_id=?2 AND status='unresolved'`,
  ).bind(row.recipe_candidate_id, row.source_occurrence_id, input.publicVersionId)));
  const candidates = [...new Set(unresolved.results.map((row) => row.recipe_candidate_id))];
  const ready: string[] = [];
  for (const recipeId of candidates) {
    const remaining = await db.prepare("SELECT COUNT(*) AS count FROM recipe_ingredient_dependencies_v2 WHERE recipe_candidate_id=?1 AND status='unresolved'")
      .bind(recipeId).first<{ count: number }>();
    if (Number(remaining?.count ?? 0) !== 0) continue;
    ready.push(recipeId);
    const eventId = await deterministicId("recipe-resume-v4", input.publicVersionId, recipeId);
    await db.prepare(
      `INSERT OR IGNORE INTO recipe_incremental_projection_events
         (id, ingredient_public_version_id, affected_recipe_id, projection_type, state)
       VALUES (?1, ?2, ?3, 'recipe_resume', 'queued')`,
    ).bind(eventId, input.publicVersionId, recipeId).run();
  }
  return { satisfied: unresolved.results.length, readyRecipeIds: ready };
}

export async function blockRecipesForUnavailableIngredient(db: D1Database, ingredientId: string) {
  const rows = await db.prepare("SELECT recipe_candidate_id, source_occurrence_id FROM recipe_ingredient_dependencies_v2 WHERE ingredient_id=?1 AND status='unresolved'")
    .bind(ingredientId).all<{ recipe_candidate_id: string; source_occurrence_id: string }>();
  if (rows.results.length) await db.batch(rows.results.map((row) => db.prepare(
    `UPDATE recipe_ingredient_dependencies_v2 SET status='permanently_unavailable', resolved_at=CURRENT_TIMESTAMP
     WHERE recipe_candidate_id=?1 AND source_occurrence_id=?2 AND status='unresolved'`,
  ).bind(row.recipe_candidate_id, row.source_occurrence_id)));
  return { blockedOccurrences: rows.results.length, recipeIds: [...new Set(rows.results.map((row) => row.recipe_candidate_id))] };
}

export async function completePermanentlyUnavailableIngredient(db: D1Database, input: {
  pricingJobId: string; ingredientId: string; definitionVersionId: string; resolutionEventId: string;
}) {
  const job = await db.prepare(`SELECT entity_id,operational_state,not_found_store_count,priced_store_count
    FROM ingredient_pricing_jobs WHERE id=?1`).bind(input.pricingJobId)
    .first<{ entity_id: string; operational_state: string; not_found_store_count: number; priced_store_count: number }>();
  const definition = await db.prepare(`SELECT definition_hash,identity_json FROM catalog_ingredient_versions
    WHERE version_id=?1 AND ingredient_id=?2`).bind(input.definitionVersionId, input.ingredientId)
    .first<{ definition_hash: string; identity_json: string }>();
  const checks = await db.prepare(`SELECT COUNT(*) AS count FROM ingredient_store_checks
    WHERE pricing_job_id=?1 AND operational_state='qa_verified_not_found'`).bind(input.pricingJobId).first<{ count: number }>();
  if (!job || job.entity_id !== input.ingredientId || job.operational_state !== "permanently_unavailable"
    || Number(job.not_found_store_count) !== 7 || Number(job.priced_store_count) !== 0 || Number(checks?.count) !== 7 || !definition) {
    throw new Error("permanent-unavailable completion requires seven independently verified not-found checks");
  }
  const identity = JSON.parse(definition.identity_json) as { aliases?: string[] };
  await db.batch([
    db.prepare(`INSERT INTO catalog_permanently_unavailable
      (ingredient_id,identity_version_id,identity_hash,normalized_aliases_json,resolution_event_id)
      VALUES(?1,?2,?3,?4,?5) ON CONFLICT(ingredient_id) DO NOTHING`)
      .bind(input.ingredientId, input.definitionVersionId, definition.definition_hash, JSON.stringify(identity.aliases ?? []), input.resolutionEventId),
    db.prepare("UPDATE catalog_ingredient_current SET current_state='permanently_unavailable',pointer_generation=pointer_generation+1,updated_at=CURRENT_TIMESTAMP WHERE ingredient_id=?1 AND current_version_id=?2")
      .bind(input.ingredientId, input.definitionVersionId),
    db.prepare("DELETE FROM ingredient_pricing_inbox WHERE pricing_job_id=?1").bind(input.pricingJobId),
  ]);
  return blockRecipesForUnavailableIngredient(db, input.ingredientId);
}
