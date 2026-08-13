import type { ReleaseGuardResult } from "@thriftycrew/contracts";
import { stableJson } from "@thriftycrew/domain";
import { upsertGuardResult } from "./database";
import type { WorkerEnv } from "./env";

function guard(guardId: string, findings: ReleaseGuardResult["findings"], eligibleCount: number, detail: Record<string, unknown> = {}): ReleaseGuardResult {
  return { guardId, status: findings.length === 0 ? "pass" : "fail", eligibleCount, examinedCount: eligibleCount, findings, detail };
}

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function array(value: unknown): Array<Record<string, unknown>> {
  return Array.isArray(value) ? value.filter((item): item is Record<string, unknown> => Boolean(item) && typeof item === "object" && !Array.isArray(item)) : [];
}

async function payload(env: WorkerEnv, releaseId: string, kind: string): Promise<unknown> {
  const row = await env.DB.prepare("SELECT payload_json, object_key FROM release_payloads WHERE release_id = ?1 AND kind = ?2").bind(releaseId, kind).first<{ payload_json: string; object_key: string | null }>();
  if (!row) return null;
  if (!row.object_key) return JSON.parse(row.payload_json);
  const object = await env.EVIDENCE.get(row.object_key);
  return object ? object.json() : null;
}

export async function evaluateReleaseIntegrity(env: WorkerEnv, releaseId: string): Promise<void> {
  const costs = await env.DB.prepare(
    `SELECT recipe_slug, status, batch_cost_minor, serving_cost_minor, servings, detail_json
       FROM release_recipe_costs WHERE release_id = ?1 ORDER BY recipe_slug`,
  ).bind(releaseId).all<{ recipe_slug: string; status: string; batch_cost_minor: number | null; serving_cost_minor: number | null; servings: number; detail_json: string }>();
  const bundles = await env.DB.prepare(
    "SELECT recipe_slug, content_hash, object_key, byte_length FROM release_recipe_payload_refs WHERE release_id = ?1 ORDER BY recipe_slug",
  ).bind(releaseId).all<{ recipe_slug: string; content_hash: string; object_key: string; byte_length: number }>();
  const expectedSlugs = costs.results.map((cost) => cost.recipe_slug).sort();
  const actualSlugs = bundles.results.map((bundle) => bundle.recipe_slug).sort();
  const bundleFindings: ReleaseGuardResult["findings"] = [];
  if (stableJson(expectedSlugs) !== stableJson(actualSlugs)) bundleFindings.push({
    key: "recipe-bundle-coverage",
    message: "Per-recipe object coverage differs from authored recipe costs",
    evidence: { expected: expectedSlugs.length, actual: actualSlugs.length },
  });
  for (const bundle of bundles.results) if (!/^[a-f0-9]{64}$/.test(bundle.content_hash) || bundle.byte_length <= 0
    || !(bundle.object_key.startsWith(`releases/${releaseId}/recipes/`) || bundle.object_key === `recipe-bundles/v2/${bundle.content_hash}.json`)) {
    bundleFindings.push({ key: bundle.recipe_slug, message: "Recipe bundle metadata is invalid", evidence: bundle });
  }
  await upsertGuardResult(env.DB, releaseId, guard("release-recipe-bundles", bundleFindings, costs.results.length, { storage: "R2", granularity: "one object per recipe" }));
  const observationRows = await env.DB.prepare(
    `SELECT o.id, o.purchase_price_minor, o.normalized_basis_unit, o.normalized_basis_qty_micros,
            o.membership_required, o.loyalty_required
       FROM release_input_batches input
       JOIN capture_batch_observations member ON member.batch_id = input.batch_id
       JOIN observations o ON o.id = member.observation_id
      WHERE input.release_id = ?1`,
  ).bind(releaseId).all<{ id: string; purchase_price_minor: number; normalized_basis_unit: string; normalized_basis_qty_micros: number; membership_required: number; loyalty_required: number }>();
  const observations = new Map(observationRows.results.map((row) => [row.id, row]));
  const arithmeticFindings: ReleaseGuardResult["findings"] = [];
  const conversionFindings: ReleaseGuardResult["findings"] = [];
  const releaseRegistry = await env.DB.prepare(
    `SELECT json_extract(input_manifest_json, '$.ingredientConversionRegistry.contentHash') AS content_hash,
            CAST(json_extract(input_manifest_json, '$.ingredientConversionRegistry.entryCount') AS INTEGER) AS entry_count
       FROM releases WHERE id = ?1`,
  ).bind(releaseId).first<{ content_hash: string | null; entry_count: number | null }>();
  for (const cost of costs.results) {
    let detail: Record<string, unknown>;
    try { detail = record(JSON.parse(cost.detail_json)); } catch { detail = {}; }
    const ingredients = array(detail.ingredients);
    const priced = ingredients.filter((ingredient) => ingredient.status === "priced");
    if (cost.status !== "complete") continue;
    const utilized = priced.reduce((sum, ingredient) => sum + Number(ingredient.utilizedCostMinor ?? 0), 0);
    const checkout = priced.reduce((sum, ingredient) => sum + Number(ingredient.purchaseCostMinor ?? 0), 0);
    const nonMemberComplete = priced.every((ingredient) => ingredient.nonMemberUtilizedCostMinor !== null && ingredient.nonMemberPurchaseCostMinor !== null);
    const nonMemberUtilized = priced.reduce((sum, ingredient) => sum + Number(ingredient.nonMemberUtilizedCostMinor ?? 0), 0);
    const nonMemberCheckout = priced.reduce((sum, ingredient) => sum + Number(ingredient.nonMemberPurchaseCostMinor ?? 0), 0);
    if (priced.length !== Number(detail.ingredientCount) || utilized !== cost.batch_cost_minor || utilized !== Number(detail.utilizedBatchCostMinor)
      || Math.round(utilized / cost.servings) !== cost.serving_cost_minor || checkout !== Number(detail.splitStoreCheckoutCostMinor)
      || (nonMemberComplete && (nonMemberUtilized !== Number(detail.nonMemberUtilizedBatchCostMinor) || nonMemberCheckout !== Number(detail.nonMemberSplitStoreCheckoutCostMinor) || Math.round(nonMemberUtilized / cost.servings) !== Number(detail.nonMemberServingCostMinor)))
      || (!nonMemberComplete && (detail.nonMemberUtilizedBatchCostMinor !== null || detail.nonMemberSplitStoreCheckoutCostMinor !== null || detail.nonMemberServingCostMinor !== null))) {
      arithmeticFindings.push({ key: `total:${cost.recipe_slug}`, message: "Recipe totals do not recompute from priced ingredient lines", evidence: { storedBatchMinor: cost.batch_cost_minor, recomputedUtilizedMinor: utilized, storedServingMinor: cost.serving_cost_minor, recomputedServingMinor: Math.round(utilized / cost.servings), storedCheckoutMinor: detail.splitStoreCheckoutCostMinor, recomputedCheckoutMinor: checkout, pricedIngredients: priced.length, declaredIngredients: detail.ingredientCount } });
    }
    for (const [index, ingredient] of priced.entries()) {
      const observationId = String(ingredient.observationId ?? "");
      const observation = observations.get(observationId);
      const checkoutObservationId = String(ingredient.checkoutObservationId ?? observationId);
      const checkoutObservation = observations.get(checkoutObservationId);
      const grams = Number(ingredient.grams);
      const gpu = Number(ingredient.gpu);
      const perUnitMicros = Number(ingredient.perUnitMicros);
      const declaredGpu = ingredient.gpuSource === "recipe-scaler" ? Number(ingredient.scalerGpu) : Number(ingredient.definitionGpu);
      const expectedUtilized = Math.round(perUnitMicros * (grams / gpu) / 10_000);
      const checkoutPerUnitMicros = Number(ingredient.checkoutPerUnitMicros ?? perUnitMicros);
      const checkoutPurchasePriceMinor = Number(ingredient.checkoutSourcePurchasePriceMinor ?? ingredient.sourcePurchasePriceMinor);
      const checkoutPackageBasisUnits = checkoutPurchasePriceMinor * 10_000 / checkoutPerUnitMicros;
      const checkoutVariableWeight = ingredient.checkoutVariableWeight === true || (ingredient.checkoutVariableWeight === undefined && ingredient.variableWeight === true);
      const expectedPackages = checkoutVariableWeight ? 0 : Math.max(1, Math.ceil((grams / gpu) / checkoutPackageBasisUnits - 1e-9));
      const expectedCheckout = checkoutVariableWeight
        ? Math.round(checkoutPerUnitMicros * (grams / gpu) / 10_000)
        : checkoutPurchasePriceMinor * expectedPackages;
      if (!observation || gpu !== declaredGpu || !Number.isFinite(expectedUtilized) || !Number.isFinite(expectedPackages) || expectedUtilized !== Number(ingredient.utilizedCostMinor)
        || expectedCheckout !== Number(ingredient.purchaseCostMinor)
        || expectedPackages !== Number(ingredient.packageCount)
        || observation.purchase_price_minor !== Number(ingredient.sourcePurchasePriceMinor)
        || observation.normalized_basis_unit !== ingredient.sourceNormalizedBasisUnit
        || observation.normalized_basis_qty_micros !== Number(ingredient.sourceNormalizedBasisQtyMicros)
        || !checkoutObservation
        || checkoutObservation.purchase_price_minor !== checkoutPurchasePriceMinor
        || checkoutObservation.normalized_basis_unit !== (ingredient.checkoutSourceNormalizedBasisUnit ?? ingredient.sourceNormalizedBasisUnit)
        || checkoutObservation.normalized_basis_qty_micros !== Number(ingredient.checkoutSourceNormalizedBasisQtyMicros ?? ingredient.sourceNormalizedBasisQtyMicros)) {
        arithmeticFindings.push({ key: `line:${cost.recipe_slug}:${index}`, message: "Recipe ingredient line is not reproducible from its immutable utilized and checkout source observations", evidence: { observationId, checkoutObservationId, expectedUtilizedMinor: expectedUtilized, expectedCheckoutMinor: expectedCheckout, ingredient, sourceObservation: observation ?? null, checkoutSourceObservation: checkoutObservation ?? null } });
      }
      if (!releaseRegistry?.content_hash || ingredient.conversionRegistryHash !== releaseRegistry.content_hash
        || typeof ingredient.conversionId !== "string" || !ingredient.conversionId
        || !["recipe-scaler-exception", "ingredient-definition", "commodity-mass-unit"].includes(String(ingredient.conversionSource))
        || ingredient.conversionConfidence !== "moderate") {
        conversionFindings.push({ key: `${cost.recipe_slug}:${index}`, message: "Recipe ingredient conversion is outside the immutable governed registry", evidence: { ingredient: ingredient.item, conversionId: ingredient.conversionId ?? null, conversionRegistryHash: ingredient.conversionRegistryHash ?? null, releaseRegistryHash: releaseRegistry?.content_hash ?? null } });
      }
    }
  }
  await upsertGuardResult(env.DB, releaseId, guard("release-recipe-arithmetic", arithmeticFindings, costs.results.length, { authority: "server recomputation over immutable release observations" }));
  await upsertGuardResult(env.DB, releaseId, guard("release-conversion-registry", conversionFindings, costs.results.length, { registryHash: releaseRegistry?.content_hash ?? null, registryEntries: releaseRegistry?.entry_count ?? 0 }));

  const [topRows, rotationRows] = await Promise.all([
    env.DB.prepare(
      `SELECT top.protein, top.rank, top.recipe_slug, top.serving_cost_minor, costs.batch_cost_minor, costs.serving_cost_minor AS authoritative_serving
         FROM release_top5 top LEFT JOIN release_recipe_costs costs ON costs.release_id = top.release_id AND costs.recipe_slug = top.recipe_slug
        WHERE top.release_id = ?1 ORDER BY top.protein, top.rank`,
    ).bind(releaseId).all<{ protein: string; rank: number; recipe_slug: string; serving_cost_minor: number; batch_cost_minor: number | null; authoritative_serving: number | null }>(),
    env.DB.prepare("SELECT protein, rank, recipe_slug, intended_visibility FROM release_free_rotation WHERE release_id = ?1 ORDER BY protein, rank").bind(releaseId).all<{ protein: string; rank: number; recipe_slug: string; intended_visibility: string }>(),
  ]);
  const rankingFindings: ReleaseGuardResult["findings"] = [];
  const costDetail = new Map(costs.results.map((cost) => {
    try { return [cost.recipe_slug, record(JSON.parse(cost.detail_json))] as const; } catch { return [cost.recipe_slug, {}] as const; }
  }));
  const rankIdentity = (rows: Array<{ protein: unknown; rank: unknown; recipeSlug: unknown }>) => rows.map((row) => ({ protein: String(row.protein), rank: Number(row.rank), recipeSlug: String(row.recipeSlug) })).sort((left, right) => left.protein.localeCompare(right.protein) || left.rank - right.rank || left.recipeSlug.localeCompare(right.recipeSlug));
  const expectedTop = rankIdentity(["chicken", "turkey", "beef", "pork"].flatMap((protein) => costs.results
    .filter((cost) => cost.status === "complete" && costDetail.get(cost.recipe_slug)?.protein === protein && Number(costDetail.get(cost.recipe_slug)?.calories ?? 0) > 500)
    .sort((left, right) => left.serving_cost_minor! - right.serving_cost_minor! || left.batch_cost_minor! - right.batch_cost_minor! || left.recipe_slug.localeCompare(right.recipe_slug))
    .slice(0, 5)
    .map((cost, index) => ({ protein, rank: index + 1, recipeSlug: cost.recipe_slug }))));
  for (const protein of new Set(topRows.results.map((row) => row.protein))) {
    const rows = topRows.results.filter((row) => row.protein === protein);
    rows.forEach((row, index) => {
      if (row.rank !== index + 1 || row.serving_cost_minor !== row.authoritative_serving || (index > 0 && rows[index - 1]!.serving_cost_minor > row.serving_cost_minor)) {
        rankingFindings.push({ key: `${protein}:${row.rank}`, message: "Top-five row is not contiguous, sorted, or equal to the authoritative recipe cost", evidence: row });
      }
    });
  }
  const topIdentity = rankIdentity(topRows.results.map((row) => ({ protein: row.protein, rank: row.rank, recipeSlug: row.recipe_slug })));
  const rotationIdentity = rankIdentity(rotationRows.results.map((row) => ({ protein: row.protein, rank: row.rank, recipeSlug: row.recipe_slug })));
  if (stableJson(topIdentity) !== stableJson(rotationIdentity) || rotationRows.results.some((row) => row.intended_visibility !== "public")) {
    rankingFindings.push({ key: "free-rotation", message: "Free rotation is not an exact public projection of the price-ranked Top 5", evidence: { topIdentity, rotationIdentity } });
  }
  if (stableJson(topIdentity) !== stableJson(expectedTop)) rankingFindings.push({ key: "top5-selection", message: "Top-five rows are not the server-recomputed cheapest eligible recipes", evidence: { expectedTop, actualTop: topIdentity } });
  await upsertGuardResult(env.DB, releaseId, guard("release-ranking-consistency", rankingFindings, topRows.results.length + rotationRows.results.length));

  const [boardPayload, recipesPayload, topPayload, rotationPayload, feedPayload] = await Promise.all(["board", "recipes", "top5", "free_rotation", "feed"].map((kind) => payload(env, releaseId, kind)));
  const payloadFindings: ReleaseGuardResult["findings"] = [];
  const cells = await env.DB.prepare("SELECT commodity_id, store_location_id, observation_id, display_per_unit_micros, display_unit FROM release_cells WHERE release_id = ?1 AND status = 'priced' ORDER BY commodity_id, store_location_id").bind(releaseId).all<{ commodity_id: string; store_location_id: string; observation_id: string; display_per_unit_micros: number; display_unit: string }>();
  const boardCells = array(record(boardPayload).commodities).flatMap((commodity) => array(commodity.stores).map((store) => ({ commodity_id: String(commodity.id), store_location_id: String(store.storeLocationId), observation_id: String(store.observationId), display_per_unit_micros: Number(store.perUnitMicros), display_unit: String(store.unit) }))).sort((left, right) => left.commodity_id.localeCompare(right.commodity_id) || left.store_location_id.localeCompare(right.store_location_id));
  if (stableJson(boardCells) !== stableJson(cells.results)) payloadFindings.push({ key: "board", message: "Board payload cells differ from authoritative release cells", evidence: { payloadCells: boardCells.length, tableCells: cells.results.length } });
  const recipePayloadRows = array(record(recipesPayload).recipes).map((recipe) => ({ recipe_slug: String(recipe.slug), status: String(recipe.status), batch_cost_minor: recipe.batchCostMinor === null ? null : Number(recipe.batchCostMinor), serving_cost_minor: recipe.servingCostMinor === null ? null : Number(recipe.servingCostMinor), split_store_checkout_minor: recipe.splitStoreCheckoutCostMinor === null ? null : Number(recipe.splitStoreCheckoutCostMinor), non_member_checkout_minor: recipe.nonMemberSplitStoreCheckoutCostMinor === null ? null : Number(recipe.nonMemberSplitStoreCheckoutCostMinor), single_store_checkout_minor: recipe.bestSingleStoreCheckoutCostMinor === null ? null : Number(recipe.bestSingleStoreCheckoutCostMinor) })).sort((left, right) => left.recipe_slug.localeCompare(right.recipe_slug));
  const costRows = costs.results.map((cost) => {
    let detail: Record<string, unknown> = {};
    try { detail = record(JSON.parse(cost.detail_json)); } catch { /* the arithmetic guard reports malformed detail */ }
    return { recipe_slug: cost.recipe_slug, status: cost.status, batch_cost_minor: cost.batch_cost_minor, serving_cost_minor: cost.serving_cost_minor, split_store_checkout_minor: detail.splitStoreCheckoutCostMinor ?? null, non_member_checkout_minor: detail.nonMemberSplitStoreCheckoutCostMinor ?? null, single_store_checkout_minor: detail.bestSingleStoreCheckoutCostMinor ?? null };
  });
  if (stableJson(recipePayloadRows) !== stableJson(costRows)) payloadFindings.push({ key: "recipes", message: "Recipe payload costs differ from authoritative recipe-cost rows", evidence: { payloadRecipes: recipePayloadRows.length, tableRecipes: costRows.length } });
  if (stableJson(rankIdentity(array(record(topPayload).entries).map((row) => ({ protein: row.protein, rank: row.rank, recipeSlug: row.recipeSlug })))) !== stableJson(topIdentity)) payloadFindings.push({ key: "top5", message: "Top-five payload differs from its authoritative rows", evidence: {} });
  if (stableJson(rankIdentity(array(record(rotationPayload).entries).map((row) => ({ protein: row.protein, rank: row.rank, recipeSlug: row.recipeSlug })))) !== stableJson(rotationIdentity)) payloadFindings.push({ key: "free-rotation", message: "Free-rotation payload differs from its authoritative rows", evidence: {} });
  if (String(record(feedPayload).release_id ?? "") !== releaseId) payloadFindings.push({ key: "feed", message: "Feed payload is not bound to this release", evidence: { payloadReleaseId: record(feedPayload).release_id, releaseId } });
  await upsertGuardResult(env.DB, releaseId, guard("release-payload-consistency", payloadFindings, 5));
}
