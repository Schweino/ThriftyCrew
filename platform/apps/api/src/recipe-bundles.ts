import { digestHex, stableJson } from "@thriftycrew/domain";
import recipeCommodityAliases from "../../../config/recipe-commodity-aliases.json";
import type { WorkerEnv } from "./env";

type PayloadRow = { payload_json: string; object_key: string | null };

async function releasePayload(env: WorkerEnv, releaseId: string, kind: string): Promise<Record<string, unknown>> {
  const row = await env.DB.prepare(
    "SELECT payload_json, object_key FROM release_payloads WHERE release_id = ?1 AND kind = ?2",
  ).bind(releaseId, kind).first<PayloadRow>();
  if (!row) throw new Error(`release ${releaseId} is missing ${kind} payload`);
  const value = row.object_key ? await env.EVIDENCE.get(row.object_key).then((object) => object?.json()) : JSON.parse(row.payload_json);
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`release ${releaseId} has invalid ${kind} payload`);
  return value as Record<string, unknown>;
}

function object(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function array(value: unknown): Array<Record<string, unknown>> {
  return Array.isArray(value) ? value.filter((item): item is Record<string, unknown> => Boolean(item) && typeof item === "object" && !Array.isArray(item)) : [];
}

export function recipeFeedIngredients(
  allIngredients: Record<string, unknown>,
  commodityIds: string[],
  aliases: Record<string, string> = recipeCommodityAliases,
): Record<string, unknown> {
  const ingredients: Record<string, unknown> = Object.fromEntries(
    commodityIds.filter((id) => allIngredients[id] !== undefined).map((id) => [id, allIngredients[id]]),
  );
  for (const [alias, target] of Object.entries(aliases)) {
    if (!commodityIds.includes(target) || ingredients[target] === undefined || ingredients[alias] !== undefined) continue;
    const targetIngredient = object(ingredients[target]);
    ingredients[alias] = { ...targetIngredient, alias_of: target };
  }
  return ingredients;
}

export async function buildReleaseRecipeBundles(
  env: WorkerEnv,
  releaseId: string,
  afterSlug = "",
  limit = 40,
): Promise<{ count: number; bytes: number; uploadedObjects: number; reusedObjects: number; next: string | null }> {
  const [recipesPayload, feedPayload, costs] = await Promise.all([
    releasePayload(env, releaseId, "recipes"),
    releasePayload(env, releaseId, "feed"),
    env.DB.prepare(
      "SELECT recipe_slug, detail_json FROM release_recipe_costs WHERE release_id = ?1 AND recipe_slug > ?2 ORDER BY recipe_slug LIMIT ?3",
    ).bind(releaseId, afterSlug, Math.max(1, Math.min(100, limit))).all<{ recipe_slug: string; detail_json: string }>(),
  ]);
  const recipes = array(recipesPayload.recipes);
  const recipeBySlug = new Map(recipes.map((recipe) => [String(recipe.slug), recipe]));
  const allIngredients = object(feedPayload.ingredients);
  const feedRecipes = object(feedPayload.recipes);
  const writes: Array<{ slug: string; hash: string; key: string; bytes: Uint8Array; detailHash: string; detailKey: string; detailBytes: Uint8Array }> = [];
  for (const cost of costs.results) {
    const recipe = recipeBySlug.get(cost.recipe_slug);
    if (!recipe) throw new Error(`recipe payload is missing ${cost.recipe_slug}`);
    const detail = object(JSON.parse(cost.detail_json));
    const commodityIds = [...new Set(array(detail.ingredients).map((ingredient) => ingredient.commodityId)
      .filter((value): value is string => typeof value === "string" && value.length > 0))].sort();
    const ingredients = recipeFeedIngredients(allIngredients, commodityIds);
    const pricingInputs = Object.fromEntries(array(detail.ingredients).flatMap((ingredient) => {
      const commodityId = typeof ingredient.commodityId === "string" ? ingredient.commodityId : null;
      if (!commodityId || ingredient.status !== "priced") return [];
      return [[commodityId, {
        current: {
          observationId: ingredient.checkoutObservationId ?? ingredient.observationId ?? null,
          storeLocationId: ingredient.checkoutStoreLocationId ?? null,
          store: ingredient.checkoutStore ?? ingredient.store ?? null,
          perUnitMicros: ingredient.checkoutPerUnitMicros ?? ingredient.perUnitMicros ?? null,
          unit: ingredient.checkoutBasisUnit ?? ingredient.basisUnit ?? null,
          purchasePriceMinor: ingredient.checkoutSourcePurchasePriceMinor ?? ingredient.sourcePurchasePriceMinor ?? null,
          packageBasisUnits: ingredient.checkoutPackageBasisUnits ?? ingredient.packageBasisUnits ?? null,
          variableWeight: ingredient.checkoutVariableWeight === true || (ingredient.checkoutVariableWeight === undefined && ingredient.variableWeight === true),
          url: ingredient.checkoutProductUrl ?? null,
        },
        everyday: {
          observationId: ingredient.everydayObservationId ?? null, storeLocationId: ingredient.everydayStoreLocationId ?? null,
          store: ingredient.everydayStore ?? null,
          perUnitMicros: ingredient.everydayPerUnitMicros ?? null,
          unit: ingredient.everydayBasisUnit ?? null,
          purchasePriceMinor: ingredient.everydaySourcePurchasePriceMinor ?? null,
          packageBasisUnits: ingredient.everydayPackageBasisUnits ?? null,
          variableWeight: ingredient.everydayVariableWeight === true,
          url: ingredient.everydayProductUrl ?? null,
        },
        stores: ingredient.storeOptions ?? {},
      }]];
    }));
    const feed = {
      version: feedPayload.version,
      ingredient_count: Object.keys(ingredients).length,
      recipe_count: feedRecipes[cost.recipe_slug] ? 1 : 0,
      board_item_count: Object.keys(ingredients).length,
      ingredients,
      pricing_inputs: pricingInputs,
      scenarios: detail.scenarios ?? {},
      recipes: feedRecipes[cost.recipe_slug] ? { [cost.recipe_slug]: feedRecipes[cost.recipe_slug] } : {},
    };
    // Delivery objects are release-neutral. The read path hydrates the current
    // release metadata, allowing unchanged recipes to share this object across
    // the copy-on-write graph instead of being rewritten for every promotion.
    const serialized = stableJson({ version: 2, slug: cost.recipe_slug, recipe, feed });
    const hash = await digestHex(serialized);
    const bytes = new TextEncoder().encode(serialized);
    const detailSerialized = stableJson(detail);
    const detailHash = await digestHex(detailSerialized);
    const detailBytes = new TextEncoder().encode(detailSerialized);
    writes.push({ slug: cost.recipe_slug, hash, key: `recipe-bundles/v2/${hash}.json`, bytes,
      detailHash, detailKey: `recipe-cost-details/${detailHash}.json`, detailBytes });
  }
  const placeholders = writes.map((_, index) => `?${index + 1}`).join(",");
  const [knownBundles, knownDetails] = writes.length === 0 ? [{ results: [] }, { results: [] }] : await Promise.all([
    env.DB.prepare(`SELECT content_hash, object_key FROM release_recipe_payload_refs WHERE content_hash IN (${placeholders}) GROUP BY content_hash`).bind(...writes.map((write) => write.hash)).all<{ content_hash: string; object_key: string }>(),
    env.DB.prepare(`SELECT content_hash, object_key FROM recipe_cost_detail_objects WHERE content_hash IN (${placeholders}) GROUP BY content_hash`).bind(...writes.map((write) => write.detailHash)).all<{ content_hash: string; object_key: string }>(),
  ]);
  const bundleObjects = new Map(knownBundles.results.map((row) => [row.content_hash, row.object_key]));
  const detailObjects = new Map(knownDetails.results.map((row) => [row.content_hash, row.object_key]));
  for (const write of writes) {
    write.key = bundleObjects.get(write.hash) ?? write.key;
    write.detailKey = detailObjects.get(write.detailHash) ?? write.detailKey;
  }
  const uploads = writes.flatMap((write) => [
    ...(!bundleObjects.has(write.hash) ? [{ key: write.key, bytes: write.bytes, metadata: { sha256: write.hash, kind: "recipe-bundle", recipeSlug: write.slug } }] : []),
    ...(!detailObjects.has(write.detailHash) ? [{ key: write.detailKey, bytes: write.detailBytes, metadata: { sha256: write.detailHash, kind: "recipe-cost-detail" } }] : []),
  ]);
  for (let offset = 0; offset < uploads.length; offset += 40) {
    await Promise.all(uploads.slice(offset, offset + 40).map((upload) =>
      env.EVIDENCE.put(upload.key, upload.bytes, {
        httpMetadata: { contentType: "application/json; charset=utf-8" },
        customMetadata: upload.metadata,
      })));
  }
  const statements = writes.flatMap((write) => [env.DB.prepare(
    `INSERT INTO release_recipe_payload_refs (release_id, recipe_slug, content_hash, object_key, byte_length)
     VALUES (?1, ?2, ?3, ?4, ?5)
     ON CONFLICT(release_id, recipe_slug) DO UPDATE SET
       content_hash = excluded.content_hash, object_key = excluded.object_key, byte_length = excluded.byte_length`,
  ).bind(releaseId, write.slug, write.hash, write.key, write.bytes.byteLength), env.DB.prepare(
    `INSERT INTO recipe_cost_detail_objects
       (release_id, recipe_slug, content_hash, object_key, byte_length)
     VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT(release_id, recipe_slug) DO UPDATE SET
       content_hash = excluded.content_hash, object_key = excluded.object_key, byte_length = excluded.byte_length`,
  ).bind(releaseId, write.slug, write.detailHash, write.detailKey, write.detailBytes.byteLength)]);
  for (let offset = 0; offset < statements.length; offset += 80) await env.DB.batch(statements.slice(offset, offset + 80));
  return { count: writes.length, bytes: writes.reduce((sum, write) => sum + write.bytes.byteLength, 0),
    uploadedObjects: uploads.length, reusedObjects: writes.length * 2 - uploads.length,
    next: writes.length === Math.max(1, Math.min(100, limit)) ? writes.at(-1)!.slug : null };
}

export function hydrateReleaseRecipeBundle(bundle: Record<string, unknown>, releaseId: string, publishedAt: string, weekOf: string): Record<string, unknown> {
  return { ...bundle, releaseId, feed: { ...object(bundle.feed), release_id: releaseId, generated: publishedAt, week_of: weekOf } };
}

export async function buildReleaseRecipeDetailArchive(env: WorkerEnv, releaseId: string): Promise<{ count: number; bytes: number }> {
  const costs = await env.DB.prepare(
    "SELECT recipe_slug, detail_json FROM release_recipe_costs WHERE release_id = ?1 ORDER BY recipe_slug",
  ).bind(releaseId).all<{ recipe_slug: string; detail_json: string }>();
  const recipes: Record<string, unknown> = {};
  for (const cost of costs.results) recipes[cost.recipe_slug] = JSON.parse(cost.detail_json);
  const serialized = stableJson({ version: 1, releaseId, recipes });
  const hash = await digestHex(serialized);
  const bytes = new TextEncoder().encode(serialized);
  const key = `recipe-cost-detail-archives/${hash}.json`;
  await env.EVIDENCE.put(key, bytes, {
    httpMetadata: { contentType: "application/json; charset=utf-8" },
    customMetadata: { sha256: hash, kind: "recipe-cost-detail-archive", releaseId },
  });
  const stored = await env.EVIDENCE.head(key);
  if (!stored || stored.size !== bytes.byteLength || stored.customMetadata?.sha256 !== hash) {
    throw new Error(`recipe detail archive verification failed for ${releaseId}`);
  }
  const statements = costs.results.map((cost) => env.DB.prepare(
    `INSERT INTO recipe_cost_detail_objects
       (release_id, recipe_slug, content_hash, object_key, byte_length, verified_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT(release_id, recipe_slug) DO UPDATE SET
       content_hash = excluded.content_hash, object_key = excluded.object_key,
       byte_length = excluded.byte_length, verified_at = excluded.verified_at`,
  ).bind(releaseId, cost.recipe_slug, hash, key, bytes.byteLength, new Date().toISOString()));
  for (let offset = 0; offset < statements.length; offset += 80) await env.DB.batch(statements.slice(offset, offset + 80));
  return { count: costs.results.length, bytes: bytes.byteLength };
}

export async function compactReleaseRecipeDetails(env: WorkerEnv, releaseId: string): Promise<{ releaseId: string; compacted: number; bytesReleased: number }> {
  const release = await env.DB.prepare("SELECT state FROM releases WHERE id = ?1").bind(releaseId).first<{ state: string }>();
  if (!release) throw new Error(`release ${releaseId} does not exist`);
  if (release.state !== "superseded") throw new Error("recipe detail compaction is restricted to superseded releases");
  const rows = await env.DB.prepare(
    `SELECT detail.recipe_slug, detail.content_hash, detail.object_key, detail.byte_length,
            costs.detail_json
       FROM recipe_cost_detail_objects detail
       JOIN release_recipe_costs costs ON costs.release_id = detail.release_id AND costs.recipe_slug = detail.recipe_slug
      WHERE detail.release_id = ?1 AND detail.compacted_at IS NULL ORDER BY detail.recipe_slug`,
  ).bind(releaseId).all<{ recipe_slug: string; content_hash: string; object_key: string; byte_length: number; detail_json: string }>();
  const uniqueObjects = [...new Map(rows.results.map((row) => [row.object_key, row])).values()];
  for (let offset = 0; offset < uniqueObjects.length; offset += 20) {
    const chunk = uniqueObjects.slice(offset, offset + 20);
    const heads = await Promise.all(chunk.map((row) => env.EVIDENCE.head(row.object_key)));
    heads.forEach((head, index) => {
      const row = chunk[index]!;
      if (!head || head.size !== row.byte_length || head.customMetadata?.sha256 !== row.content_hash) throw new Error(`recipe detail object verification failed for ${releaseId}/${row.recipe_slug}`);
    });
  }
  const verified = rows.results;
  const now = new Date().toISOString();
  const statements = verified.flatMap((row) => [env.DB.prepare(
    `UPDATE release_recipe_costs SET detail_json = ?3
      WHERE release_id = ?1 AND recipe_slug = ?2`,
  ).bind(releaseId, row.recipe_slug, stableJson({ archived: true, contentHash: row.content_hash, objectKey: row.object_key })), env.DB.prepare(
    `UPDATE recipe_cost_detail_objects SET verified_at = ?3, compacted_at = ?3
      WHERE release_id = ?1 AND recipe_slug = ?2 AND compacted_at IS NULL`,
  ).bind(releaseId, row.recipe_slug, now)]);
  for (let offset = 0; offset < statements.length; offset += 80) await env.DB.batch(statements.slice(offset, offset + 80));
  return { releaseId, compacted: verified.length, bytesReleased: verified.reduce((sum, row) => sum + new TextEncoder().encode(row.detail_json).byteLength, 0) };
}

export async function readCurrentRecipeBundle(env: WorkerEnv, slug: string): Promise<{
  releaseId: string; publishedAt: string; contentHash: string; bundle: Record<string, unknown>;
} | null> {
  const row = await env.DB.prepare(
    `SELECT r.id AS release_id, r.published_at,
            json_extract(r.input_manifest_json, '$.releaseDate') AS week_of,
            payload.content_hash, payload.object_key
       FROM current_releases current
       JOIN releases r ON r.id = current.release_id
       JOIN release_recipe_payload_refs payload ON payload.release_id = r.id AND payload.recipe_slug = ?1
      WHERE current.market_id = 'omaha'`,
  ).bind(slug).first<{ release_id: string; published_at: string; week_of: string; content_hash: string; object_key: string }>();
  if (!row) return null;
  const bundle = await env.EVIDENCE.get(row.object_key).then((item) => item?.json<Record<string, unknown>>());
  if (!bundle) throw new Error(`published recipe bundle ${row.object_key} is unavailable`);
  return { releaseId: row.release_id, publishedAt: row.published_at, contentHash: row.content_hash,
    bundle: hydrateReleaseRecipeBundle(bundle, row.release_id, row.published_at, row.week_of) };
}
