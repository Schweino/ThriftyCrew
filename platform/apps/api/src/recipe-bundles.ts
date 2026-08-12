import { digestHex, stableJson } from "@thriftycrew/domain";
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

export async function buildReleaseRecipeBundles(env: WorkerEnv, releaseId: string): Promise<{ count: number; bytes: number }> {
  const [recipesPayload, feedPayload, costs] = await Promise.all([
    releasePayload(env, releaseId, "recipes"),
    releasePayload(env, releaseId, "feed"),
    env.DB.prepare("SELECT recipe_slug, detail_json FROM release_recipe_costs WHERE release_id = ?1 ORDER BY recipe_slug")
      .bind(releaseId).all<{ recipe_slug: string; detail_json: string }>(),
  ]);
  const recipes = array(recipesPayload.recipes);
  const recipeBySlug = new Map(recipes.map((recipe) => [String(recipe.slug), recipe]));
  const allIngredients = object(feedPayload.ingredients);
  const feedRecipes = object(feedPayload.recipes);
  const writes: Array<{ slug: string; hash: string; key: string; bytes: Uint8Array }> = [];
  for (const cost of costs.results) {
    const recipe = recipeBySlug.get(cost.recipe_slug);
    if (!recipe) throw new Error(`recipe payload is missing ${cost.recipe_slug}`);
    const detail = object(JSON.parse(cost.detail_json));
    const commodityIds = [...new Set(array(detail.ingredients).map((ingredient) => ingredient.commodityId)
      .filter((value): value is string => typeof value === "string" && value.length > 0))].sort();
    const ingredients = Object.fromEntries(commodityIds.filter((id) => allIngredients[id] !== undefined).map((id) => [id, allIngredients[id]]));
    const feed = {
      version: feedPayload.version,
      release_id: feedPayload.release_id,
      generated: feedPayload.generated,
      week_of: feedPayload.week_of,
      ingredient_count: Object.keys(ingredients).length,
      recipe_count: feedRecipes[cost.recipe_slug] ? 1 : 0,
      board_item_count: Object.keys(ingredients).length,
      ingredients,
      recipes: feedRecipes[cost.recipe_slug] ? { [cost.recipe_slug]: feedRecipes[cost.recipe_slug] } : {},
    };
    const serialized = stableJson({ version: 1, releaseId, slug: cost.recipe_slug, recipe, feed });
    const hash = await digestHex(serialized);
    const bytes = new TextEncoder().encode(serialized);
    writes.push({ slug: cost.recipe_slug, hash, key: `releases/${releaseId}/recipes/${cost.recipe_slug}-${hash}.json`, bytes });
  }
  for (let offset = 0; offset < writes.length; offset += 20) {
    await Promise.all(writes.slice(offset, offset + 20).map((write) => env.EVIDENCE.put(write.key, write.bytes, {
      httpMetadata: { contentType: "application/json; charset=utf-8" },
      customMetadata: { sha256: write.hash, releaseId, recipeSlug: write.slug },
    })));
  }
  const statements = writes.map((write) => env.DB.prepare(
    `INSERT INTO release_recipe_payloads (release_id, recipe_slug, content_hash, object_key, byte_length)
     VALUES (?1, ?2, ?3, ?4, ?5)
     ON CONFLICT(release_id, recipe_slug) DO UPDATE SET
       content_hash = excluded.content_hash, object_key = excluded.object_key, byte_length = excluded.byte_length`,
  ).bind(releaseId, write.slug, write.hash, write.key, write.bytes.byteLength));
  for (let offset = 0; offset < statements.length; offset += 80) await env.DB.batch(statements.slice(offset, offset + 80));
  return { count: writes.length, bytes: writes.reduce((sum, write) => sum + write.bytes.byteLength, 0) };
}

export async function readCurrentRecipeBundle(env: WorkerEnv, slug: string): Promise<{
  releaseId: string; publishedAt: string; contentHash: string; bundle: Record<string, unknown>;
} | null> {
  const row = await env.DB.prepare(
    `SELECT r.id AS release_id, r.published_at, payload.content_hash, payload.object_key
       FROM current_releases current
       JOIN releases r ON r.id = current.release_id
       JOIN release_recipe_payloads payload ON payload.release_id = r.id AND payload.recipe_slug = ?1
      WHERE current.market_id = 'omaha'`,
  ).bind(slug).first<{ release_id: string; published_at: string; content_hash: string; object_key: string }>();
  if (!row) return null;
  const bundle = await env.EVIDENCE.get(row.object_key).then((item) => item?.json<Record<string, unknown>>());
  if (!bundle) throw new Error(`published recipe bundle ${row.object_key} is unavailable`);
  return { releaseId: row.release_id, publishedAt: row.published_at, contentHash: row.content_hash, bundle };
}
