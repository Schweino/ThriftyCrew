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
