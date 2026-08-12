import { readFile, readdir, stat } from "node:fs/promises";
import path from "node:path";
import type { ObservationInput, RecipeCost } from "@thriftycrew/contracts";
import { deterministicId, digestHex, normalizeName, stableJson } from "@thriftycrew/domain";

const STORE_IDENTITIES = {
  "Aldi": { locationId: "aldi-omaha-446-048", sourceId: "legacy-aldi", priceMode: "mixed" },
  "Baker's": { locationId: "bakers-saddle-creek", sourceId: "legacy-bakers", priceMode: "mixed" },
  "Family Fare": { locationId: "family-fare-omaha-6401", sourceId: "legacy-family-fare", priceMode: "mixed" },
  "Fareway": { locationId: "fareway-omaha-043", sourceId: "legacy-fareway", priceMode: "mixed" },
  "Hy-Vee": { locationId: "hy-vee-omaha-1465", sourceId: "legacy-hy-vee", priceMode: "mixed" },
  "Sam's Club": { locationId: "sams-omaha", sourceId: "legacy-sams", priceMode: "mixed" },
  "Walmart": { locationId: "walmart-omaha", sourceId: "legacy-walmart", priceMode: "mixed" },
} as const;

type StoreName = keyof typeof STORE_IDENTITIES;
type LegacyUnit = "lb" | "oz" | "floz" | "each" | "dozen" | "gallon";
type BasisUnit = ObservationInput["normalizedBasisUnit"];

interface LegacyStoreRow {
  store: StoreName;
  per_unit: number;
  unit: LegacyUnit;
  type: "sale" | "everyday" | "markdown" | "member";
  bulk: boolean;
  membership: boolean;
  member_label: string;
  item: string;
  ad: string;
  size: string;
  basis: string;
  note: string;
  source_ad: string;
}

interface LegacyComparisonRow {
  commodity: string;
  id: string;
  unit: LegacyUnit;
  cheapest_store: StoreName;
  cheapest_price: number;
  cheapest_type: string;
  nomem_store: StoreName;
  nomem_price: number;
  nomem_type: string;
  stores: LegacyStoreRow[];
}

interface LegacyComparison {
  built_at: string;
  week_of: string;
  source: string;
  commodities_compared: number;
  health: Record<string, unknown>;
  comparison: LegacyComparisonRow[];
}

interface LegacyCommodity {
  id: string;
  label: string;
  unit: LegacyUnit;
  include: string[];
  exclude: string[];
  band_min?: number;
  band_max?: number;
}

interface LegacyCategory {
  key: string;
  label: string;
  order: number;
  commodities: string[];
}

interface LegacyCostedRecipe {
  proposed_name: string;
  slug: string;
  cost_batch: number;
  cost_per_serving: number;
  cost_batch_true: number;
  cost_per_serving_true: number;
  cost_pantry_add: number;
  cost_first_run: number;
  lines_priced: number;
  lines_unpriced: number;
  lines: Array<Record<string, unknown>>;
}

interface ProductLink {
  url?: string;
  price?: number | string;
  size?: string;
  name?: string;
  verified?: string;
  board_pu?: number;
  recipe_pu?: number;
}

interface ProductUrlFile {
  items: Record<string, Record<string, ProductLink | string>>;
}

interface LegacyKnownWrongFile {
  entries: Array<{
    key: string;
    commodity: string;
    store: string;
    names?: string[];
    product_id?: string;
    verdict: string;
    evidence: string;
    reversed_on?: string;
    reversed_by?: string;
  }>;
}

interface LegacyFreeRotation {
  week_of: string;
  free: Array<{ slug: string; protein: string; rank: number; name: string; per_serving: number }>;
  paid?: Array<{ slug: string; protein?: string; rank?: number }>;
}

export interface LegacyObservationPlan {
  sourceId: string;
  storeLocationId: string;
  commodityId: string;
  productId: string;
  versionId: string;
  observationId: string;
  observation: ObservationInput;
}

export interface CurrentBridgeArtifact {
  version: 3;
  marketId: "omaha";
  capturedAt: string;
  weekOf: string;
  configuration: {
    id: string;
    sourceCommit: string;
    contentHash: string;
    categories: Array<{ id: string; label: string; sortOrder: number }>;
    commodities: Array<LegacyCommodity & { categoryId: string }>;
    knownWrong: Array<{
      id: string;
      commodityId: string;
      storeLocationId?: string;
      externalProductKey?: string;
      normalizedName?: string;
      ruling: string;
      evidence: string;
    }>;
  };
  stores: Array<{ name: StoreName; locationId: string; sourceId: string; priceMode: "mixed" }>;
  observations: LegacyObservationPlan[];
  cells: Array<{
    commodityId: string;
    storeLocationId: string;
    observationId?: string;
    status: "priced" | "missing";
    isCrown: boolean;
    displayPerUnitMicros?: number;
    displayUnit?: BasisUnit;
    reason: Record<string, unknown>;
  }>;
  recipeCosts: RecipeCost[];
  top5: Array<{ protein: string; rank: number; recipeSlug: string; servingCostMinor: number }>;
  freeRotation: Array<{ recipeSlug: string; intendedVisibility: "public" | "paid"; protein?: string; rank?: number }>;
  payloads: {
    board: unknown;
    feed: unknown;
    top5: unknown;
    free_rotation: unknown;
    recipes: unknown;
  };
  audit: {
    authoredCommodities: number;
    boardCommodities: number;
    pricedCells: number;
    missingCells: number;
    authoredRecipes: number;
    deployedKnownWrongNames: number;
    taxonomyPathsCaptured: number;
    sourceIncompleteRecipes: number;
    repairedRecipes: number;
    incompleteRecipes: number;
    uncategorized: string[];
    multiplyCategorized: string[];
  };
}

function basisUnit(unit: LegacyUnit): BasisUnit {
  if (unit === "floz") return "fl_oz";
  if (unit === "gallon") return "gal";
  return unit;
}

function knownWrongStoreLocation(store: string): string | undefined {
  const aliases: Record<string, StoreName> = {
    Aldi: "Aldi",
    Bakers: "Baker's",
    "Baker's": "Baker's",
    FamilyFare: "Family Fare",
    "Family Fare": "Family Fare",
    Fareway: "Fareway",
    HyVee: "Hy-Vee",
    "Hy-Vee": "Hy-Vee",
    SamsClub: "Sam's Club",
    "Sam's Club": "Sam's Club",
    Walmart: "Walmart",
  };
  const name = aliases[store];
  return name ? STORE_IDENTITIES[name].locationId : undefined;
}

function taxonomyFromLegacyUrl(store: StoreName, productUrl: string | undefined): string | undefined {
  if (!productUrl || store !== "Family Fare") return undefined;
  try {
    const segments = new URL(productUrl).pathname.split("/").filter(Boolean);
    const shopIndex = segments.indexOf("shop");
    const productIndex = segments.lastIndexOf("p");
    if (shopIndex < 0 || productIndex <= shopIndex + 1) return undefined;
    return segments.slice(shopIndex + 1, productIndex - 1).join("/") || undefined;
  } catch {
    return undefined;
  }
}

function firstNumber(text: string, pattern: RegExp): number | undefined {
  const match = text.match(pattern);
  const value = match?.[1] === undefined ? Number.NaN : Number(match[1]);
  return Number.isFinite(value) && value > 0 ? value : undefined;
}

export function inferBasisQuantity(row: Pick<LegacyStoreRow, "unit" | "size" | "basis">): number {
  const basisSize = firstNumber(row.basis, /^size\s+([0-9]+(?:\.[0-9]+)?)/i);
  const pack = firstNumber(row.basis, /^per-([0-9]+(?:\.[0-9]+)?)-pack/i);
  if (row.basis.startsWith("per-package") || row.basis.includes("marker") || row.basis.includes("rate in size")) return 1;
  if (pack !== undefined) return pack;

  // Recover an exact source quantity when the legacy normalized basis rounded
  // a conversion (for example 3 oz -> "0.188 lb").
  if (row.unit === "lb") {
    const ounces = firstNumber(row.size, /([0-9]+(?:\.[0-9]+)?)\s*oz\b/i);
    if (ounces !== undefined) return ounces / 16;
  }
  if (row.unit === "gallon") {
    const fluidOunces = firstNumber(row.size, /([0-9]+(?:\.[0-9]+)?)\s*fl\s*oz\b/i);
    if (fluidOunces !== undefined) return fluidOunces / 128;
  }
  if (row.unit === "dozen") {
    const count = firstNumber(row.size, /([0-9]+(?:\.[0-9]+)?)\s*ct\b/i);
    if (count !== undefined) return count / 12;
  }
  return basisSize ?? 1;
}

export function exactLegacyPriceBasis(perUnit: number, baseQuantity: number): {
  purchasePriceMinor: number;
  purchaseQuantity: number;
  basisQuantityMicros: number;
  deltaMicros: number;
} {
  const targetMicros = Math.round(perUnit * 1_000_000);
  let best: ReturnType<typeof candidatePriceBasis> | undefined;
  for (let multiplier = 1; multiplier <= 100; multiplier += 1) {
    const candidate = candidatePriceBasis(targetMicros, baseQuantity, multiplier);
    if (!best || candidate.deltaMicros < best.deltaMicros) best = candidate;
    if (candidate.deltaMicros <= 2) break;
  }
  if (!best) throw new Error("unable to construct legacy price basis");
  return best;
}

function candidatePriceBasis(targetMicros: number, baseQuantity: number, purchaseQuantity: number) {
  const basisQuantityMicros = Math.max(1, Math.round(baseQuantity * purchaseQuantity * 1_000_000));
  const purchasePriceMinor = Math.round((targetMicros * basisQuantityMicros) / 10_000_000_000);
  const recalculated = Math.round((purchasePriceMinor * 10_000 * 1_000_000) / basisQuantityMicros);
  return { purchasePriceMinor, purchaseQuantity, basisQuantityMicros, deltaMicros: Math.abs(recalculated - targetMicros) };
}

async function readJson<T>(file: string): Promise<T> {
  return JSON.parse((await readFile(file, "utf8")).replace(/^\uFEFF/, "")) as T;
}

async function latestComparisonFile(incomeRoot: string): Promise<string> {
  const output = path.join(incomeRoot, "grocery", "out");
  const candidates = (await readdir(output))
    .filter((name) => /^comparison-\d{4}-\d{2}-\d{2}\.json$/.test(name))
    .sort()
    .reverse();
  for (const candidate of candidates) {
    const file = path.join(output, candidate);
    if ((await stat(file)).size > 2) return file;
  }
  throw new Error("no current grocery comparison artifact found");
}

function capturedAtWithOffset(localTimestamp: string): string {
  if (/[zZ]|[+-]\d\d:\d\d$/.test(localTimestamp)) return new Date(localTimestamp).toISOString();
  // Omaha is on daylight time for the current August fixture. Native captures
  // must supply an offset themselves; this conversion exists only in the
  // legacy bridge.
  return new Date(`${localTimestamp}-05:00`).toISOString();
}

function missingRecipeIngredients(recipe: LegacyCostedRecipe, specification: { ingredients_grams?: Array<{ item: string }> }): string[] {
  if (recipe.lines_unpriced === 0) return [];
  const priced = new Set(recipe.lines.map((line) => String(line.item ?? "").toLowerCase()));
  return (specification.ingredients_grams ?? [])
    .map((ingredient) => ingredient.item)
    .filter((item) => !priced.has(item.toLowerCase()));
}

export async function buildCurrentBridge(incomeRoot: string): Promise<CurrentBridgeArtifact> {
  const comparisonFile = await latestComparisonFile(incomeRoot);
  const supplementalComparisonFile = path.join(incomeRoot, "grocery", "out", "basisfix-base.json");
  const [comparison, supplementalComparison, commodities, categoriesFile, knownWrongFile, productUrls, recipeRows, feed, rotation] = await Promise.all([
    readJson<LegacyComparison>(comparisonFile),
    readJson<LegacyComparison>(supplementalComparisonFile),
    readJson<LegacyCommodity[]>(path.join(incomeRoot, "platform", "config", "commodities.json")),
    readJson<{ categories: LegacyCategory[] }>(path.join(incomeRoot, "platform", "config", "categories.json")),
    readJson<LegacyKnownWrongFile>(path.join(incomeRoot, "platform", "config", "known-wrong.json")),
    readJson<ProductUrlFile>(path.join(incomeRoot, "grocery", "product-urls.json")),
    readJson<LegacyCostedRecipe[]>(path.join(incomeRoot, "meal-prep", "db", "costed.json")),
    readJson<unknown>(path.join(incomeRoot, "public", "smp-feed.json")),
    readJson<LegacyFreeRotation>(path.join(incomeRoot, "meal-prep", "free-rotation.json")),
  ]);
  const capturedAt = capturedAtWithOffset(comparison.built_at);
  const categoriesByCommodity = new Map<string, string[]>();
  for (const category of categoriesFile.categories) {
    for (const commodityId of category.commodities) {
      const assigned = categoriesByCommodity.get(commodityId) ?? [];
      assigned.push(category.key);
      categoriesByCommodity.set(commodityId, assigned);
    }
  }
  const uncategorized = commodities.filter((item) => !categoriesByCommodity.has(item.id)).map((item) => item.id);
  const multiplyCategorized = [...categoriesByCommodity].filter(([, ids]) => ids.length !== 1).map(([id]) => id);
  const configurationCommodities = commodities.map((commodity) => ({
    ...commodity,
    categoryId: categoriesByCommodity.get(commodity.id)?.[0] ?? "uncategorized",
  }));
  const knownWrong: CurrentBridgeArtifact["configuration"]["knownWrong"] = [];
  for (const entry of knownWrongFile.entries) {
    if (entry.reversed_on && entry.reversed_by) continue;
    const storeLocationId = knownWrongStoreLocation(entry.store);
    for (const [ordinal, name] of (entry.names ?? []).entries()) {
      const normalizedName = normalizeName(name);
      knownWrong.push({
        id: await deterministicId("known-wrong", entry.key, String(ordinal), normalizedName),
        commodityId: entry.commodity,
        ...(storeLocationId ? { storeLocationId } : {}),
        ...(entry.product_id ? { externalProductKey: entry.product_id } : {}),
        normalizedName,
        ruling: entry.verdict,
        evidence: entry.evidence,
      });
    }
  }
  const configMaterial = {
    categories: categoriesFile.categories,
    commodities: configurationCommodities,
    knownWrong,
  };
  const configurationHash = await digestHex(stableJson(configMaterial));
  const configurationId = `cfg_${configurationHash.slice(0, 20)}`;

  const rowsByCommodity = new Map(comparison.comparison.map((row) => [row.id, row]));
  const publicCommodityIds = new Set(rowsByCommodity.keys());
  const supplementalRows = supplementalComparison.comparison.filter((row) => !publicCommodityIds.has(row.id));
  const eligibleRows = [
    ...comparison.comparison.map((row) => ({ row, capturedAt, sourceFile: comparisonFile, public: true })),
    ...supplementalRows.map((row) => ({
      row,
      capturedAt: capturedAtWithOffset(supplementalComparison.built_at),
      sourceFile: supplementalComparisonFile,
      public: false,
    })),
  ];
  const observations: LegacyObservationPlan[] = [];
  for (const eligible of eligibleRows) {
    const { row } = eligible;
    for (const storeRow of row.stores) {
      const identity = STORE_IDENTITIES[storeRow.store];
      if (!identity) throw new Error(`unknown legacy store ${storeRow.store}`);
      const normalizedUnit = basisUnit(storeRow.unit);
      const priceBasis = exactLegacyPriceBasis(storeRow.per_unit, inferBasisQuantity(storeRow));
      const externalProductKey = `legacy:${row.id}`;
      const productId = await deterministicId("prod", identity.locationId, externalProductKey);
      const link = productUrls.items[row.id]?.[storeRow.store];
      const productLink = typeof link === "object" && link !== null ? link : undefined;
      const taxonomyPath = taxonomyFromLegacyUrl(storeRow.store, productLink?.url);
      const packageDetail = {
        legacyBridge: true,
        legacyBasis: storeRow.basis,
        legacyBulk: storeRow.bulk,
        sourceAd: storeRow.source_ad,
        publicComparisonEligible: eligible.public,
        sourcePerUnit: storeRow.per_unit,
        sourcePrecisionDecimals: 4,
      };
      const versionHash = await digestHex(stableJson({
        name: storeRow.item,
        sizeText: storeRow.size,
        productUrl: productLink?.url ?? null,
        imageUrl: null,
        taxonomyPath: taxonomyPath ?? null,
        package: packageDetail,
      }));
      const versionId = await deterministicId("pver", productId, versionHash);
      const kind = storeRow.membership ? "member" : storeRow.type === "markdown" ? "markdown" : storeRow.type === "sale" ? "sale" : "everyday";
      const observationId = await deterministicId("obs", `legacy-${identity.sourceId}-${path.basename(eligible.sourceFile)}`, versionId, kind, eligible.capturedAt);
      observations.push({
        sourceId: identity.sourceId,
        storeLocationId: identity.locationId,
        commodityId: row.id,
        productId,
        versionId,
        observationId,
        observation: {
          externalProductKey,
          name: storeRow.item,
          sizeText: storeRow.size,
          ...(productLink?.url ? { productUrl: productLink.url } : {}),
          ...(taxonomyPath ? { taxonomyPath } : {}),
          package: packageDetail,
          termKey: row.id,
          kind,
          currency: "USD",
          purchasePriceMinor: priceBasis.purchasePriceMinor,
          purchaseQuantity: priceBasis.purchaseQuantity,
          packageCount: 1,
          capturedBasisUnit: normalizedUnit,
          capturedBasisQtyMicros: priceBasis.basisQuantityMicros,
          normalizedBasisUnit: normalizedUnit,
          normalizedBasisQtyMicros: priceBasis.basisQuantityMicros,
          perUnitMicros: Math.round(storeRow.per_unit * 1_000_000),
          loyaltyRequired: storeRow.member_label.toLowerCase().includes("loyalty"),
          membershipRequired: storeRow.membership,
          rawPriceText: storeRow.ad,
          rawSizeText: storeRow.size,
          capturedAt: eligible.capturedAt,
          sourcePayloadKey: `${path.basename(eligible.sourceFile)}#${row.id}/${storeRow.store}`,
        },
      });
    }
  }
  const observationByCell = new Map(observations.map((item) => [`${item.commodityId}\u001f${item.storeLocationId}`, item]));
  const cells: CurrentBridgeArtifact["cells"] = [];
  for (const commodity of configurationCommodities) {
    const boardRow = rowsByCommodity.get(commodity.id);
    for (const [storeName, identity] of Object.entries(STORE_IDENTITIES) as Array<[StoreName, (typeof STORE_IDENTITIES)[StoreName]]>) {
      const planned = observationByCell.get(`${commodity.id}\u001f${identity.locationId}`);
      if (planned) {
        cells.push({
          commodityId: commodity.id,
          storeLocationId: identity.locationId,
          observationId: planned.observationId,
          status: "priced",
          isCrown: boardRow?.cheapest_store === storeName,
          displayPerUnitMicros: planned.observation.perUnitMicros,
          displayUnit: planned.observation.normalizedBasisUnit,
          reason: { source: boardRow ? "legacy-published-board" : "legacy-private-recipe-basis" },
        });
      } else {
        cells.push({
          commodityId: commodity.id,
          storeLocationId: identity.locationId,
          status: "missing",
          isCrown: false,
          reason: { code: boardRow ? "not-priced-at-store" : "not-on-published-board" },
        });
      }
    }
  }

  const recipeCosts: RecipeCost[] = [];
  const recipeSummaries: Array<Record<string, unknown>> = [];
  const sourceIncompleteRecipes = recipeRows.filter((recipe) => recipe.lines_unpriced > 0).length;
  let repairedRecipes = 0;
  const anchoObservation = observations.find((plan) => plan.commodityId === "dried-ancho-chiles");
  for (const recipe of recipeRows) {
    const specification = await readJson<{ servings?: number; ingredients_grams?: Array<{ item: string }> }>(
      path.join(incomeRoot, "meal-prep", "db", "recipes", `${recipe.slug}.json`),
    );
    const sourceMissingIngredients = missingRecipeIngredients(recipe, specification);
    const canRepairFromPrivateBasis = sourceMissingIngredients.length > 0
      && sourceMissingIngredients.every((item) => item === "Dried Ancho Chiles")
      && anchoObservation?.observation.normalizedBasisUnit === "oz";
    const servings = specification.servings ?? 14;
    const missingGrams = (specification.ingredients_grams ?? [])
      .filter((ingredient) => sourceMissingIngredients.includes(ingredient.item))
      .reduce((total, ingredient) => total + Number((ingredient as { grams?: number }).grams ?? 0), 0);
    const repairedUtilMinor = canRepairFromPrivateBasis
      ? Math.round((missingGrams / 28.349523125) * (anchoObservation.observation.perUnitMicros / 1_000_000) * 100)
      : 0;
    const repairedTrueBatchMinor = Math.round(recipe.cost_batch_true * 100) + repairedUtilMinor;
    const repairedUtilizedBatchMinor = Math.round(recipe.cost_batch * 100) + repairedUtilMinor;
    const starterMinor = canRepairFromPrivateBasis ? anchoObservation.observation.purchasePriceMinor : 0;
    const repairedPantryAddMinor = Math.round(recipe.cost_pantry_add * 100) + Math.max(0, starterMinor - repairedUtilMinor);
    const missingIngredients = canRepairFromPrivateBasis ? [] : sourceMissingIngredients;
    const complete = recipe.lines_unpriced === 0 && missingIngredients.length === 0 || canRepairFromPrivateBasis;
    if (canRepairFromPrivateBasis) repairedRecipes += 1;
    recipeCosts.push({
      recipeSlug: recipe.slug,
      status: complete ? "complete" : "incomplete",
      ...(complete ? {
        batchCostMinor: repairedTrueBatchMinor,
        servingCostMinor: Math.round(repairedTrueBatchMinor / servings),
      } : {}),
      servings,
      missingIngredients,
      detail: {
        utilizedBatchCostMinor: repairedUtilizedBatchMinor,
        utilizedServingCostMinor: Math.round(repairedUtilizedBatchMinor / servings),
        pantryAddMinor: repairedPantryAddMinor,
        firstRunMinor: repairedTrueBatchMinor + repairedPantryAddMinor,
        linesPriced: recipe.lines_priced + (canRepairFromPrivateBasis ? 1 : 0),
        linesUnpriced: canRepairFromPrivateBasis ? 0 : recipe.lines_unpriced,
        ...(canRepairFromPrivateBasis ? {
          repairedFromPrivateBasis: {
            commodityId: "dried-ancho-chiles",
            observationSourcePayloadKey: anchoObservation.observation.sourcePayloadKey,
            missingGrams,
            utilizedCostMinor: repairedUtilMinor,
          },
        } : {}),
      },
    });
    recipeSummaries.push({
      slug: recipe.slug,
      name: recipe.proposed_name,
      status: complete ? "complete" : "incomplete",
      servingCostMinor: complete ? Math.round(repairedTrueBatchMinor / servings) : null,
      missingIngredients,
    });
  }

  const top5 = rotation.free.map((item) => ({ protein: item.protein, rank: item.rank, recipeSlug: item.slug, servingCostMinor: Math.round(item.per_serving * 100) }));
  const freeRotation: CurrentBridgeArtifact["freeRotation"] = [
    ...rotation.free.map((item) => ({ recipeSlug: item.slug, intendedVisibility: "public" as const, protein: item.protein, rank: item.rank })),
    ...(rotation.paid ?? []).map((item) => ({ recipeSlug: item.slug, intendedVisibility: "paid" as const, ...(item.protein ? { protein: item.protein } : {}), ...(item.rank ? { rank: item.rank } : {}) })),
  ];

  const boardPayload = {
    version: 3,
    market: { id: "omaha", name: "Omaha, Nebraska" },
    generatedAt: capturedAt,
    weekOf: comparison.week_of,
    stores: Object.entries(STORE_IDENTITIES).map(([name, identity]) => ({ name, ...identity })),
    categories: categoriesFile.categories.map((category) => ({ id: category.key, label: category.label, sortOrder: category.order })),
    commodities: comparison.comparison.map((row) => ({
      id: row.id,
      label: row.commodity,
      unit: basisUnit(row.unit),
      categoryId: categoriesByCommodity.get(row.id)?.[0],
      cheapest: { store: row.cheapest_store, perUnitMicros: Math.round(row.cheapest_price * 1_000_000), type: row.cheapest_type },
      cheapestWithoutMembership: { store: row.nomem_store, perUnitMicros: Math.round(row.nomem_price * 1_000_000), type: row.nomem_type },
      stores: row.stores.map((store) => ({
        ...store,
        unit: basisUnit(store.unit),
        perUnitMicros: Math.round(store.per_unit * 1_000_000),
        productUrl: typeof productUrls.items[row.id]?.[store.store] === "object" ? (productUrls.items[row.id]?.[store.store] as ProductLink).url : undefined,
      })),
    })),
    health: comparison.health,
  };

  const incompleteRecipes = recipeCosts.filter((recipe) => recipe.status !== "complete").length;
  return {
    version: 3,
    marketId: "omaha",
    capturedAt,
    weekOf: comparison.week_of,
    configuration: {
      id: configurationId,
      sourceCommit: "legacy-worktree",
      contentHash: configurationHash,
      categories: categoriesFile.categories.map((category) => ({ id: category.key, label: category.label, sortOrder: category.order })),
      commodities: configurationCommodities,
      knownWrong,
    },
    stores: Object.entries(STORE_IDENTITIES).map(([name, identity]) => ({ name: name as StoreName, ...identity })),
    observations,
    cells,
    recipeCosts,
    top5,
    freeRotation,
    payloads: {
      board: boardPayload,
      feed,
      top5: { version: 3, generatedAt: capturedAt, weekOf: rotation.week_of, entries: top5 },
      free_rotation: { version: 3, generatedAt: capturedAt, weekOf: rotation.week_of, entries: freeRotation },
      recipes: { version: 3, generatedAt: capturedAt, recipes: recipeSummaries },
    },
    audit: {
      authoredCommodities: commodities.length,
      boardCommodities: comparison.comparison.length,
      pricedCells: observations.length,
      missingCells: cells.length - observations.length,
      authoredRecipes: recipeRows.length,
      deployedKnownWrongNames: knownWrong.length,
      taxonomyPathsCaptured: observations.filter((plan) => plan.observation.taxonomyPath).length,
      sourceIncompleteRecipes,
      repairedRecipes,
      incompleteRecipes,
      uncategorized,
      multiplyCategorized,
    },
  };
}
