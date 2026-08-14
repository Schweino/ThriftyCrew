import { catalogIngredientIdentitySchema } from "@thriftycrew/contracts";
import { deterministicId, digestHex, normalizeName, stableJson } from "@thriftycrew/domain";

export interface CatalogIngredientDefinitionInput {
  ingredientId: string;
  slug: string;
  sourceGapId?: string | null;
  identity: unknown;
}

export async function createCatalogIngredientVersion(db: D1Database, input: CatalogIngredientDefinitionInput) {
  const identity = catalogIngredientIdentitySchema.parse(input.identity);
  const identityJson = stableJson(identity);
  const definitionHash = await digestHex(identityJson);
  const prior = await db.prepare("SELECT COALESCE(MAX(version), 0) AS version FROM catalog_ingredient_versions WHERE ingredient_id = ?1")
    .bind(input.ingredientId).first<{ version: number }>();
  const version = Number(prior?.version ?? 0) + 1;
  const versionId = await deterministicId("ingdef", input.ingredientId, String(version), definitionHash);
  const aliases = [...new Set([identity.canonicalName, identity.displayName, ...identity.aliases].map(normalizeName))].sort();
  const statements: D1PreparedStatement[] = [db.prepare(
    `INSERT INTO catalog_ingredient_versions
       (version_id, ingredient_id, version, slug, canonical_name, display_name, identity_json, unit_dimension,
        basis_unit, source_gap_id, definition_hash, planner_run_id)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)`,
  ).bind(versionId, input.ingredientId, version, input.slug, identity.canonicalName, identity.displayName, identityJson,
    identity.unitDimension, identity.basisUnit, input.sourceGapId ?? null, definitionHash, identity.plannerRunId)];
  aliases.forEach((alias) => statements.push(db.prepare(
    `INSERT INTO catalog_ingredient_aliases
       (ingredient_id, version_id, normalized_alias, alias_type, confidence_millis, authority, source)
     VALUES (?1, ?2, ?3, ?4, 1000, 'identity-planner', ?5)`,
  ).bind(input.ingredientId, versionId, alias, alias === normalizeName(identity.canonicalName) ? "canonical" : "source", identity.plannerRunId)));
  statements.push(db.prepare(
    `INSERT INTO catalog_ingredient_current(ingredient_id, current_version_id, current_state)
     VALUES (?1, ?2, 'active') ON CONFLICT(ingredient_id) DO UPDATE SET
       current_version_id = excluded.current_version_id, current_state = 'active',
       pointer_generation = catalog_ingredient_current.pointer_generation + 1, updated_at = CURRENT_TIMESTAMP`,
  ).bind(input.ingredientId, versionId));
  await db.batch(statements);
  return { versionId, version, definitionHash, aliases };
}

export async function resolveCurrentIngredientAlias(db: D1Database, value: string) {
  return db.prepare(
    `SELECT current.ingredient_id, current.current_version_id, current.current_state, version.slug,
            version.canonical_name, version.display_name, version.definition_hash
       FROM catalog_ingredient_aliases alias
       JOIN catalog_ingredient_current current ON current.ingredient_id = alias.ingredient_id
       JOIN catalog_ingredient_versions version ON version.version_id = current.current_version_id
      WHERE alias.normalized_alias = ?1
      ORDER BY alias.confidence_millis DESC, alias.ingredient_id LIMIT 2`,
  ).bind(normalizeName(value)).all();
}
