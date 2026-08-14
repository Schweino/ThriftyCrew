import { catalogIngredientIdentitySchema } from "@thriftycrew/contracts";
import { deterministicId, digestHex, normalizeName, stableJson } from "@thriftycrew/domain";

export interface CatalogIngredientDefinitionInput {
  ingredientId: string;
  slug: string;
  sourceGapId?: string | null;
  identity: unknown;
  expectedPointerGeneration: number;
}

export async function createCatalogIngredientVersion(db: D1Database, input: CatalogIngredientDefinitionInput) {
  const identity = catalogIngredientIdentitySchema.parse(input.identity);
  const identityJson = stableJson(identity);
  const definitionHash = await digestHex(identityJson);
  const aliases = [...new Set([identity.canonicalName, identity.displayName, ...identity.aliases].map(normalizeName))].sort();
  const current = await db.prepare(`SELECT current.pointer_generation, version.version, version.definition_hash
    FROM catalog_ingredient_current current JOIN catalog_ingredient_versions version ON version.version_id=current.current_version_id
    WHERE current.ingredient_id=?1`).bind(input.ingredientId).first<{ pointer_generation: number; version: number; definition_hash: string }>();
  if (current?.definition_hash === definitionHash) return { versionId: await deterministicId("ingdef", input.ingredientId, String(current.version), definitionHash), version: current.version, definitionHash, aliases, idempotent: true };
  if (Number(current?.pointer_generation ?? 0) !== input.expectedPointerGeneration) throw new Error("ingredient definition pointer generation conflict");
  const conflicts = await db.prepare(`SELECT DISTINCT alias.ingredient_id FROM catalog_ingredient_aliases alias
    JOIN catalog_ingredient_current current ON current.ingredient_id=alias.ingredient_id AND current.current_version_id=alias.version_id
    WHERE alias.normalized_alias IN (${aliases.map((_, index) => `?${index + 1}`).join(",")}) AND alias.ingredient_id<>?${aliases.length + 1}`)
    .bind(...aliases, input.ingredientId).all<{ ingredient_id: string }>();
  if (conflicts.results.length) throw new Error("ingredient alias conflicts with another current ingredient");
  const version = Number(current?.version ?? 0) + 1;
  const versionId = await deterministicId("ingdef", input.ingredientId, String(version), definitionHash);
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
  if (input.expectedPointerGeneration === 0) statements.push(db.prepare(
    `INSERT INTO catalog_ingredient_current(ingredient_id,current_version_id,current_state,pointer_generation)
     VALUES(?1,?2,'active',1)`,
  ).bind(input.ingredientId, versionId));
  else statements.push(db.prepare(
    `UPDATE catalog_ingredient_current SET current_version_id=?2,current_state='active',pointer_generation=pointer_generation+1,updated_at=CURRENT_TIMESTAMP
     WHERE ingredient_id=?1 AND pointer_generation=?3`,
  ).bind(input.ingredientId, versionId, input.expectedPointerGeneration));
  await db.batch(statements);
  const moved = await db.prepare("SELECT current_version_id FROM catalog_ingredient_current WHERE ingredient_id=?1")
    .bind(input.ingredientId).first<{ current_version_id: string }>();
  if (moved?.current_version_id !== versionId) throw new Error("ingredient definition pointer race lost its fence");
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
