import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import type { RecipeCost } from "@thriftycrew/contracts";
import { digestHex, stableJson } from "@thriftycrew/domain";
import { buildNativeCells, type NativeEngineSnapshot, type NativeReleaseCell } from "@thriftycrew/engine";

interface IngredientDefinition {
  item: string;
  bid?: string;
  gpu?: number;
  unit?: string;
  buy_pkg_g?: number;
  buy_pkg_label?: string;
  pantry_pkg_g?: number;
  pantry_pkg_label?: string;
  bulk?: boolean;
}

interface RecipeIngredient { item: string; grams: number }
interface RecipeScalerIngredient { item: string; canon?: string; grams?: number; bid?: string; gpu?: string | number }
interface RecipeSpecification {
  slug: string;
  name: string;
  protein?: string;
  servings: number;
  visibility?: string;
  stat?: { cal?: number; protein?: number; carbs?: number; fat?: number };
  ingredients_grams?: RecipeIngredient[];
  scaler?: { ing?: RecipeScalerIngredient[] };
}

export interface NativeReleaseArtifact {
  version: 3;
  marketId: "omaha";
  generatedAt: string;
  weekOf: string;
  configurationId: string;
  inputBatchIds: string[];
  inputManifest: Record<string, unknown>;
  inputHash: string;
  releaseId: string;
  cells: Array<{
    commodityId: string; storeLocationId: string; observationId?: string; status: "priced" | "missing";
    isCrown: boolean; displayPerUnitMicros?: number; displayUnit?: string; reason: Record<string, unknown>;
  }>;
  recipeCosts: RecipeCost[];
  top5: Array<{ protein: string; rank: number; recipeSlug: string; servingCostMinor: number }>;
  freeRotation: Array<{ recipeSlug: string; intendedVisibility: "public"; protein: string; rank: number }>;
  payloads: Record<"board" | "feed" | "top5" | "free_rotation" | "recipes", unknown>;
  audit: Record<string, unknown>;
}

function key(value: string): string {
  return value.trim().toLocaleLowerCase("en-US").replaceAll(/\s+/g, " ");
}

function moneyMinor(perUnitMicros: number, basisQuantity: number): number {
  return Math.round(perUnitMicros * basisQuantity / 10_000);
}

function asNumber(value: unknown): number | undefined {
  const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
  return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}

function publicCell(cell: NativeReleaseCell): NativeReleaseArtifact["cells"][number] {
  if (cell.status === "priced" && cell.observationId && cell.displayPerUnitMicros !== null && cell.displayUnit) {
    return {
      commodityId: cell.commodityId,
      storeLocationId: cell.storeLocationId,
      observationId: cell.observationId,
      status: "priced",
      isCrown: cell.isCrown,
      displayPerUnitMicros: cell.displayPerUnitMicros,
      displayUnit: cell.displayUnit,
      reason: cell.reason,
    };
  }
  return { commodityId: cell.commodityId, storeLocationId: cell.storeLocationId, status: "missing", isCrown: false, reason: cell.reason };
}

export async function buildNativeRelease(incomeRoot: string, snapshot: NativeEngineSnapshot): Promise<NativeReleaseArtifact> {
  if (snapshot.mode !== "direct") throw new Error("native publication requires a direct-only immutable engine snapshot");
  const recipeDirectory = path.join(incomeRoot, "meal-prep", "db", "recipes");
  const [ingredientBytes, recipeNames] = await Promise.all([
    readFile(path.join(incomeRoot, "meal-prep", "db", "ingredients.json"), "utf8"),
    readdir(recipeDirectory),
  ]);
  const ingredientDefinitions = JSON.parse(ingredientBytes.replace(/^\uFEFF/, "")) as IngredientDefinition[];
  const recipes = (await Promise.all(recipeNames.filter((name) => name.endsWith(".json")).sort().map(async (name) =>
    JSON.parse((await readFile(path.join(recipeDirectory, name), "utf8")).replace(/^\uFEFF/, "")) as RecipeSpecification,
  ))).sort((left, right) => left.slug.localeCompare(right.slug));
  const recipeCatalogHash = await digestHex(stableJson(recipes));
  const ingredientCatalogHash = await digestHex(stableJson(ingredientDefinitions));
  const generatedAt = snapshot.observedAt;
  const weekOf = generatedAt.slice(0, 10);
  const inputBatchIds = [...snapshot.inputBatchIds].sort();
  const inputManifest = {
    kind: "native-v3-release",
    engineVersion: "native-v3.1.0",
    marketId: "omaha",
    mode: "direct",
    releaseDate: weekOf,
    configurationId: snapshot.configurationId,
    engineSnapshotHash: snapshot.inputHash,
    recipeCatalogHash,
    ingredientCatalogHash,
  };
  const inputHash = await digestHex(stableJson({ inputManifest, inputBatchIds }));
  const releaseId = `rel_native_${inputHash.slice(0, 20)}`;

  const nativeCells = buildNativeCells(snapshot);
  const cells = nativeCells.map(publicCell);
  const crownByCommodity = new Map(nativeCells.filter((cell) => cell.isCrown && cell.winner).map((cell) => [cell.commodityId, cell]));
  const commodityById = new Map(snapshot.commodities.map((commodity) => [commodity.id, commodity]));
  const storeById = new Map(snapshot.stores.map((store) => [store.id, store]));
  const ingredientByName = new Map(ingredientDefinitions.filter((item) => item.item).map((item) => [key(item.item), item]));
  const commodityByLabel = new Map(snapshot.commodities.map((commodity) => [key(commodity.label), commodity.id]));

  const recipeCosts: RecipeCost[] = [];
  const recipePayload: Array<Record<string, unknown>> = [];
  const missingFrequency = new Map<string, number>();
  for (const recipe of recipes) {
    const scalerByName = new Map((recipe.scaler?.ing ?? []).map((item) => [key(item.item), item]));
    const ingredientDetails: Array<Record<string, unknown>> = [];
    const missingIngredients: string[] = [];
    let utilizedBatchMinor = 0;
    let trueBatchMinor = 0;
    let pantryAddMinor = 0;
    for (const ingredient of recipe.ingredients_grams ?? []) {
      const scaler = scalerByName.get(key(ingredient.item));
      const definition = ingredientByName.get(key(scaler?.canon ?? ingredient.item)) ?? ingredientByName.get(key(ingredient.item));
      const requestedBid = scaler?.bid ?? definition?.bid;
      const commodityId = requestedBid && commodityById.has(requestedBid)
        ? requestedBid
        : commodityByLabel.get(key(scaler?.canon ?? ingredient.item));
      const gpu = asNumber(scaler?.gpu) ?? asNumber(definition?.gpu);
      const grams = asNumber(ingredient.grams);
      const crown = commodityId ? crownByCommodity.get(commodityId) : undefined;
      const packageGrams = definition?.bulk ? asNumber(definition.pantry_pkg_g) : asNumber(definition?.buy_pkg_g);
      const missing: string[] = [];
      if (!commodityId) missing.push("commodity-mapping");
      if (!gpu) missing.push("grams-per-basis-unit");
      if (!grams) missing.push("ingredient-grams");
      if (!crown?.winner || crown.displayPerUnitMicros === null) missing.push("priced-release-cell");
      if (!definition?.bulk && !packageGrams) missing.push("purchase-package-size");
      if (missing.length > 0) {
        missingIngredients.push(ingredient.item);
        missingFrequency.set(`${ingredient.item}: ${missing.join(",")}`, (missingFrequency.get(`${ingredient.item}: ${missing.join(",")}`) ?? 0) + 1);
        ingredientDetails.push({ item: ingredient.item, grams: ingredient.grams, commodityId: commodityId ?? null, status: "missing", reasons: missing });
        continue;
      }
      const utilizedMinor = moneyMinor(crown!.displayPerUnitMicros!, grams! / gpu!);
      const purchaseUnits = packageGrams! / gpu!;
      const packages = definition!.bulk ? 0 : Math.max(1, Math.ceil(grams! / packageGrams! - 1e-9));
      const purchaseMinor = definition!.bulk ? utilizedMinor : moneyMinor(crown!.displayPerUnitMicros!, purchaseUnits * packages);
      const pantryContainerMinor = definition!.bulk ? moneyMinor(crown!.displayPerUnitMicros!, purchaseUnits) : 0;
      utilizedBatchMinor += utilizedMinor;
      trueBatchMinor += purchaseMinor;
      pantryAddMinor += Math.max(0, pantryContainerMinor - utilizedMinor);
      ingredientDetails.push({
        item: ingredient.item,
        grams: grams!,
        commodityId: commodityId!,
        observationId: crown!.observationId,
        store: storeById.get(crown!.storeLocationId)?.store_name ?? crown!.storeLocationId,
        perUnitMicros: crown!.displayPerUnitMicros,
        basisUnit: crown!.displayUnit,
        gpu: gpu!,
        utilizedCostMinor: utilizedMinor,
        purchaseCostMinor: purchaseMinor,
        packageCount: packages,
        packageLabel: definition!.bulk ? definition!.pantry_pkg_label : definition!.buy_pkg_label,
        pantry: Boolean(definition!.bulk),
        status: "priced",
      });
    }
    const complete = missingIngredients.length === 0 && (recipe.ingredients_grams?.length ?? 0) > 0;
    const servingCostMinor = complete ? Math.round(trueBatchMinor / recipe.servings) : undefined;
    const cost: RecipeCost = {
      recipeSlug: recipe.slug,
      status: complete ? "complete" : "incomplete",
      ...(complete ? { batchCostMinor: trueBatchMinor, servingCostMinor } : {}),
      servings: recipe.servings,
      missingIngredients: [...new Set(missingIngredients)].sort(),
      detail: {
        pricingAuthority: "native-release-crowns",
        utilizedBatchCostMinor: utilizedBatchMinor,
        utilizedServingCostMinor: Math.round(utilizedBatchMinor / recipe.servings),
        pantryAddMinor,
        firstRunMinor: trueBatchMinor + pantryAddMinor,
        ingredientCount: recipe.ingredients_grams?.length ?? 0,
        ingredients: ingredientDetails,
      },
    };
    recipeCosts.push(cost);
    recipePayload.push({
      slug: recipe.slug,
      name: recipe.name,
      protein: recipe.protein ?? null,
      visibility: recipe.visibility ?? "paid",
      servings: recipe.servings,
      calories: recipe.stat?.cal ?? null,
      status: cost.status,
      servingCostMinor: cost.servingCostMinor ?? null,
      batchCostMinor: cost.batchCostMinor ?? null,
      missingIngredients: cost.missingIngredients,
    });
  }

  const costBySlug = new Map(recipeCosts.map((cost) => [cost.recipeSlug, cost]));
  const rankedProteins = ["chicken", "turkey", "beef", "pork"] as const;
  const top5 = rankedProteins.flatMap((protein) => recipes
    .filter((recipe) => recipe.protein === protein && (recipe.stat?.cal ?? 0) > 500 && costBySlug.get(recipe.slug)?.status === "complete")
    .sort((left, right) => {
      const leftCost = costBySlug.get(left.slug)!;
      const rightCost = costBySlug.get(right.slug)!;
      return leftCost.servingCostMinor! - rightCost.servingCostMinor!
        || leftCost.batchCostMinor! - rightCost.batchCostMinor!
        || left.slug.localeCompare(right.slug);
    })
    .slice(0, 5)
    .map((recipe, index) => ({ protein, rank: index + 1, recipeSlug: recipe.slug, servingCostMinor: costBySlug.get(recipe.slug)!.servingCostMinor! })));
  const freeRotation = top5.map((entry) => ({ recipeSlug: entry.recipeSlug, intendedVisibility: "public" as const, protein: entry.protein, rank: entry.rank }));

  const categories = [...new Map(snapshot.commodities.map((commodity) => [commodity.category_id, {
    id: commodity.category_id,
    label: commodity.category_label ?? commodity.category_id,
    sortOrder: commodity.sort_order ?? 999,
  }])).values()].sort((left, right) => left.sortOrder - right.sortOrder || left.id.localeCompare(right.id));
  const boardCommodities = snapshot.commodities.map((commodity) => {
    const commodityCells = nativeCells.filter((cell) => cell.commodityId === commodity.id && cell.status === "priced" && cell.winner);
    const crown = commodityCells.find((cell) => cell.isCrown);
    const stores = commodityCells.map((cell) => ({
      store: storeById.get(cell.storeLocationId)?.store_name ?? cell.storeLocationId,
      storeLocationId: cell.storeLocationId,
      perUnitMicros: cell.displayPerUnitMicros,
      unit: cell.displayUnit,
      membership: cell.winner!.membership_required === 1,
      member_label: cell.winner!.loyalty_required === 1 ? "Loyalty price" : cell.winner!.membership_required === 1 ? "Membership required" : "",
      item: cell.winner!.name ?? "",
      size: cell.winner!.size_text ?? "",
      ad: cell.winner!.raw_price_text ?? "",
      productUrl: cell.winner!.product_url ?? undefined,
      taxonomyPath: cell.winner!.taxonomy_path ?? undefined,
      capturedAt: cell.winner!.captured_at,
    }));
    return {
      id: commodity.id,
      label: commodity.label,
      unit: commodity.basis_unit,
      categoryId: commodity.category_id,
      cheapest: crown ? { store: storeById.get(crown.storeLocationId)?.store_name ?? crown.storeLocationId, storeLocationId: crown.storeLocationId, perUnitMicros: crown.displayPerUnitMicros } : null,
      stores,
    };
  });
  const boardPayload = {
    version: 3,
    releaseId,
    market: { id: "omaha", name: "Omaha, Nebraska" },
    generatedAt,
    weekOf,
    stores: snapshot.stores.map((store) => ({ id: store.id, name: store.store_name, displayName: store.display_name ?? store.store_name, membershipProgram: store.membership_program ?? null })),
    categories,
    commodities: boardCommodities,
  };
  const feedIngredients = Object.fromEntries(boardCommodities.filter((commodity) => commodity.cheapest).map((commodity) => [commodity.id, {
    unit: commodity.unit === "fl_oz" ? "floz" : commodity.unit,
    cheapest: commodity.cheapest!.perUnitMicros! / 1_000_000,
    store: commodity.cheapest!.store,
    type: "everyday",
    url: commodity.stores.find((store) => store.storeLocationId === commodity.cheapest!.storeLocationId)?.productUrl ?? "",
    n: commodity.stores.length,
    stores: Object.fromEntries(commodity.stores.map((store) => [store.store, store.perUnitMicros! / 1_000_000])),
  }]));
  const feedRecipes = Object.fromEntries(recipePayload.filter((recipe) => recipe.status === "complete").map((recipe) => [String(recipe.slug), {
    name: recipe.name,
    servings: recipe.servings,
    week_cost: Number(((Number(recipe.batchCostMinor) || 0) / 100).toFixed(2)),
    per_serving: Number(((Number(recipe.servingCostMinor) || 0) / 100).toFixed(2)),
    calories: recipe.calories,
    sale_items: [],
  }]));
  const top5Payload = { version: 3, releaseId, generatedAt, weekOf, entries: top5 };
  const rotationPayload = { version: 3, releaseId, generatedAt, weekOf, entries: freeRotation };
  const feedPayload = {
    version: 3,
    release_id: releaseId,
    generated: generatedAt,
    week_of: weekOf,
    ingredient_count: Object.keys(feedIngredients).length,
    recipe_count: Object.keys(feedRecipes).length,
    board_item_count: boardCommodities.filter((commodity) => commodity.cheapest).length,
    ingredients: feedIngredients,
    recipes: feedRecipes,
    top5: top5Payload,
    free_rotation: rotationPayload,
  };
  const incomplete = recipeCosts.filter((cost) => cost.status === "incomplete");
  return {
    version: 3,
    marketId: "omaha",
    generatedAt,
    weekOf,
    configurationId: snapshot.configurationId,
    inputBatchIds,
    inputManifest,
    inputHash,
    releaseId,
    cells,
    recipeCosts,
    top5,
    freeRotation,
    payloads: {
      board: boardPayload,
      feed: feedPayload,
      top5: top5Payload,
      free_rotation: rotationPayload,
      recipes: { version: 3, releaseId, generatedAt, recipes: recipePayload },
    },
    audit: {
      mode: snapshot.mode,
      inputBatchCount: inputBatchIds.length,
      commodities: snapshot.commodities.length,
      stores: snapshot.stores.length,
      pricedCells: cells.filter((cell) => cell.status === "priced").length,
      missingCells: cells.filter((cell) => cell.status === "missing").length,
      authoredRecipes: recipes.length,
      completeRecipes: recipeCosts.length - incomplete.length,
      incompleteRecipes: incomplete.length,
      top5Entries: top5.length,
      rotationEntries: freeRotation.length,
      missingIngredientFrequency: [...missingFrequency.entries()].sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0])).slice(0, 100),
    },
  };
}
