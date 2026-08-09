import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import type { RecipeCost } from "@thriftycrew/contracts";
import { digestHex, normalizeName, stableJson } from "@thriftycrew/domain";
import { buildNativeCells, candidatePriceForUnit, convertUnitPriceMicros, selectWinner, type NativeEngineSnapshot, type NativeReleaseCell } from "@thriftycrew/engine";

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

interface RecipeCommodityRule {
  id: string; label: string; unit: string; include: string[]; exclude: string[];
  relax_global?: string[]; band_min?: number; band_max?: number; grams_per_unit?: number;
}

interface KnownWrongDocument {
  entries?: Array<{ commodity?: string; store?: string; names?: string[]; product_id?: string; reversed_on?: string; reversed_by?: string }>;
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

function compilePattern(value: string): RegExp {
  return new RegExp(value.replace(/^\(\?i\)/, ""), "i");
}

function apiUnit(value: string): string {
  return value === "floz" ? "fl_oz" : value === "gallon" ? "gal" : value;
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
  const configRoot = path.join(incomeRoot, "platform", "config");
  const [ingredientBytes, recipeNames, recipeRuleBytes, recipeExtensionBytes, aliasBytes, knownWrongBytes] = await Promise.all([
    readFile(path.join(incomeRoot, "meal-prep", "db", "ingredients.json"), "utf8"),
    readdir(recipeDirectory),
    readFile(path.join(configRoot, "recipe-commodities.json"), "utf8"),
    readFile(path.join(configRoot, "recipe-commodity-extensions.json"), "utf8"),
    readFile(path.join(configRoot, "recipe-commodity-aliases.json"), "utf8"),
    readFile(path.join(configRoot, "known-wrong.json"), "utf8"),
  ]);
  const ingredientDefinitions = JSON.parse(ingredientBytes.replace(/^\uFEFF/, "")) as IngredientDefinition[];
  const recipes = (await Promise.all(recipeNames.filter((name) => name.endsWith(".json")).sort().map(async (name) =>
    JSON.parse((await readFile(path.join(recipeDirectory, name), "utf8")).replace(/^\uFEFF/, "")) as RecipeSpecification,
  ))).sort((left, right) => left.slug.localeCompare(right.slug));
  const recipeRuleDocument = JSON.parse(recipeRuleBytes.replace(/^\uFEFF/, "")) as { global_exclude?: string[]; commodities: RecipeCommodityRule[] };
  const recipeExtensions = JSON.parse(recipeExtensionBytes.replace(/^\uFEFF/, "")) as { commodities: RecipeCommodityRule[] };
  const recipeAliases = JSON.parse(aliasBytes.replace(/^\uFEFF/, "")) as Record<string, string>;
  const knownWrong = JSON.parse(knownWrongBytes.replace(/^\uFEFF/, "")) as KnownWrongDocument;
  // Narrow recipe extensions precede broad legacy rules and carry their own
  // explicit exclusions, so they do not inherit the legacy global filter.
  const extensionIds = new Set(recipeExtensions.commodities.map((rule) => rule.id));
  const recipeRules = [...recipeExtensions.commodities, ...recipeRuleDocument.commodities];
  const recipeRuleIds = new Set(recipeRules.map((rule) => rule.id));
  const recipeCatalogHash = await digestHex(stableJson(recipes));
  const ingredientCatalogHash = await digestHex(stableJson(ingredientDefinitions));
  const recipePricingConfigurationHash = await digestHex(stableJson({ recipeRuleDocument, recipeExtensions, recipeAliases }));
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
    recipePricingConfigurationHash,
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

  const compiledGlobal = (recipeRuleDocument.global_exclude ?? []).map((source) => ({ source, expression: compilePattern(source) }));
  const compiledRules = recipeRules.map((rule) => ({
    rule,
    includes: rule.include.map(compilePattern),
    excludes: rule.exclude.map(compilePattern),
    relaxed: new Set(rule.relax_global ?? []),
    applyGlobal: !extensionIds.has(rule.id),
  }));
  const rawByObservation = new Map((snapshot.rawCandidates ?? []).map((candidate) => [candidate.observation_id, candidate]));
  type RawCandidate = NonNullable<NativeEngineSnapshot["rawCandidates"]>[number];
  const recipeCandidates = new Map<string, Array<{ raw: RawCandidate; convertedMicros: number }>>();
  const recipeRuleStats = new Map(recipeRules.map((rule) => [rule.id, { includeHits: 0, globalBlocked: 0, excluded: 0, incompatibleUnits: 0, outOfBand: 0, accepted: 0, samples: [] as Array<Record<string, unknown>> }]));
  const recipeMatchingAudit = { rawProducts: snapshot.rawCandidates?.length ?? 0, matched: 0, outOfBand: 0, incompatibleUnits: 0, globallyBlocked: 0 };
  for (const raw of snapshot.rawCandidates ?? []) {
    const rawText = raw.name.toLocaleLowerCase("en-US");
    const includeVariant = rawText.replace(/,?\s*priced per\s+\w+/g, "").replace(/\band\b/g, " ").replace(/\s{2,}/g, " ").trim();
    const globalHits = compiledGlobal.filter((pattern) => pattern.expression.test(rawText));
    let selected: typeof compiledRules[number] | undefined;
    for (const rule of compiledRules) {
      if (!rule.includes.some((pattern) => pattern.test(rawText) || pattern.test(includeVariant))) continue;
      const stats = recipeRuleStats.get(rule.rule.id)!;
      stats.includeHits += 1;
      if (stats.samples.length < 5) stats.samples.push({ name: raw.name, capturedUnit: raw.normalized_basis_unit, perUnitMicros: raw.per_unit_micros, size: raw.size_text ?? null });
      if (rule.applyGlobal && globalHits.some((pattern) => !rule.relaxed.has(pattern.source))) { stats.globalBlocked += 1; continue; }
      if (rule.excludes.some((pattern) => pattern.test(rawText))) { stats.excluded += 1; continue; }
      selected = rule;
      break;
    }
    if (!selected) {
      if (globalHits.length > 0) recipeMatchingAudit.globallyBlocked += 1;
      continue;
    }
    const targetUnit = apiUnit(selected.rule.unit);
    let convertedMicros = candidatePriceForUnit(raw, targetUnit)?.perUnitMicros ?? null;
    if (convertedMicros === null && ((raw.normalized_basis_unit === "oz" && targetUnit === "fl_oz") || (raw.normalized_basis_unit === "fl_oz" && targetUnit === "oz"))) {
      convertedMicros = raw.per_unit_micros;
    }
    if (convertedMicros === null && targetUnit === "each" && selected.rule.grams_per_unit && (raw.normalized_basis_unit === "lb" || raw.normalized_basis_unit === "oz")) {
      const gramsInCapturedUnit = raw.normalized_basis_unit === "lb" ? 453.59237 : 28.349523125;
      convertedMicros = Math.round(raw.per_unit_micros * selected.rule.grams_per_unit / gramsInCapturedUnit);
    }
    if (convertedMicros === null) {
      recipeMatchingAudit.incompatibleUnits += 1;
      recipeRuleStats.get(selected.rule.id)!.incompatibleUnits += 1;
      continue;
    }
    const dollars = convertedMicros / 1_000_000;
    if ((selected.rule.band_min !== undefined && dollars < selected.rule.band_min) || (selected.rule.band_max !== undefined && dollars > selected.rule.band_max)) {
      recipeMatchingAudit.outOfBand += 1;
      recipeRuleStats.get(selected.rule.id)!.outOfBand += 1;
      continue;
    }
    const list = recipeCandidates.get(selected.rule.id) ?? [];
    list.push({ raw, convertedMicros });
    recipeCandidates.set(selected.rule.id, list);
    recipeMatchingAudit.matched += 1;
    recipeRuleStats.get(selected.rule.id)!.accepted += 1;
  }
  const activeKnownWrong = (knownWrong.entries ?? []).filter((entry) => !(entry.reversed_on && entry.reversed_by));
  const recipeCrownByCommodity = new Map<string, { commodityId: string; storeLocationId: string; observationId: string; displayPerUnitMicros: number; displayUnit: string; raw: RawCandidate }>();
  for (const rule of recipeRules) {
    const storeWinners: Array<{ commodityId: string; storeLocationId: string; observationId: string; displayPerUnitMicros: number; displayUnit: string; raw: RawCandidate }> = [];
    const candidatesByStore = new Map<string, Array<{ raw: RawCandidate; convertedMicros: number }>>();
    for (const candidate of recipeCandidates.get(rule.id) ?? []) {
      const list = candidatesByStore.get(candidate.raw.store_location_id) ?? [];
      list.push(candidate);
      candidatesByStore.set(candidate.raw.store_location_id, list);
    }
    for (const [storeLocationId, candidates] of candidatesByStore) {
      const storeName = storeById.get(storeLocationId)?.store_name ?? storeLocationId;
      const selected = selectWinner(candidates.map((candidate) => ({
        observationId: candidate.raw.observation_id,
        commodityId: rule.id,
        storeLocationId,
        perUnitMicros: candidate.convertedMicros,
        capturedAt: candidate.raw.captured_at,
        batchCoverageMode: candidate.raw.coverage_mode,
        batchCapturedTo: candidate.raw.captured_to,
        ...(candidate.raw.valid_to ? { validTo: candidate.raw.valid_to } : {}),
        ...(candidate.raw.max_age_days !== undefined ? { maxAgeDays: candidate.raw.max_age_days } : {}),
        knownWrong: activeKnownWrong.some((wrong) => wrong.commodity === rule.id
          && (!wrong.store || normalizeName(wrong.store) === normalizeName(storeName))
          && ((wrong.product_id && wrong.product_id === candidate.raw.external_key)
            || (wrong.names ?? []).some((name) => normalizeName(name) === normalizeName(candidate.raw.name)))),
      })), generatedAt).winner;
      if (!selected) continue;
      const raw = rawByObservation.get(selected.observationId);
      if (!raw) throw new Error(`recipe winner ${selected.observationId} is absent from its immutable raw snapshot`);
      storeWinners.push({ commodityId: rule.id, storeLocationId, observationId: selected.observationId, displayPerUnitMicros: selected.perUnitMicros, displayUnit: apiUnit(rule.unit), raw });
    }
    const crown = storeWinners.sort((left, right) => left.displayPerUnitMicros - right.displayPerUnitMicros || left.storeLocationId.localeCompare(right.storeLocationId))[0];
    if (crown) recipeCrownByCommodity.set(rule.id, crown);
  }

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
      const requestedBids = [...new Set([scaler?.bid, definition?.bid].filter((value): value is string => Boolean(value)))];
      const aliasedBids = requestedBids.map((bid) => recipeAliases[bid]).filter((bid): bid is string => Boolean(bid));
      const resolvedBid = requestedBids.find((bid) => commodityById.has(bid) || recipeRuleIds.has(bid))
        ?? aliasedBids.find((bid) => commodityById.has(bid) || recipeRuleIds.has(bid));
      const commodityId = resolvedBid ?? commodityByLabel.get(key(scaler?.canon ?? ingredient.item));
      const gpu = asNumber(scaler?.gpu) ?? asNumber(definition?.gpu);
      const grams = asNumber(ingredient.grams);
      const boardCrown = commodityId ? crownByCommodity.get(commodityId) : undefined;
      const recipeCrown = commodityId ? recipeCrownByCommodity.get(commodityId) : undefined;
      const crown = boardCrown ?? (recipeCrown ? {
        observationId: recipeCrown.observationId,
        storeLocationId: recipeCrown.storeLocationId,
        displayPerUnitMicros: recipeCrown.displayPerUnitMicros,
        displayUnit: recipeCrown.displayUnit,
        winner: recipeCrown.raw,
      } : undefined);
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
    stores: snapshot.stores.map((store) => ({ id: store.id, name: store.store_name, displayName: store.display_name ?? store.store_name, membershipRequired: store.membership_required === 1 })),
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
      recipePricingCommodities: recipeRules.length,
      pricedRecipeCommodities: recipeCrownByCommodity.size,
      unpricedRecipeCommodities: recipeRules.filter((rule) => !recipeCrownByCommodity.has(rule.id)).map((rule) => ({ id: rule.id, ...recipeRuleStats.get(rule.id)! })),
      recipeMatching: recipeMatchingAudit,
      top5Entries: top5.length,
      rotationEntries: freeRotation.length,
      missingIngredientFrequency: [...missingFrequency.entries()].sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0])).slice(0, 100),
    },
  };
}
