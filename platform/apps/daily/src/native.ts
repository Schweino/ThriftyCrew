import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import type { RecipeCost } from "@thriftycrew/contracts";
import { digestHex, normalizeName, stableJson } from "@thriftycrew/domain";
import { buildNativeCells, candidatePriceForUnit, convertUnitPriceMicros, selectWinner, sourceNativeSizeConflict, type NativeEngineSnapshot, type NativeReleaseCell } from "@thriftycrew/engine";
import { buildContentAddressedReleaseGraph, type ContentAddressedReleaseGraph } from "./release-graph";

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

interface PricedRecipeOption {
  commodityId: string;
  storeLocationId: string;
  observationId: string;
  displayPerUnitMicros: number;
  displayUnit: string;
  raw: NonNullable<NativeEngineSnapshot["rawCandidates"]>[number] | NativeEngineSnapshot["candidates"][number];
}

interface IngredientConversionPolicy {
  version: number;
  authority: string;
  precedence: string[];
  requirements: { maximumExceptionRatio: number };
  confidence: Record<string, "moderate">;
}

interface IngredientConversionEntry {
  recipeSlug: string;
  ingredientKey: string;
  canonicalIngredientKey: string;
  gramsPerBasisUnit: number;
  source: "recipe-scaler-exception" | "ingredient-definition";
  confidence: "moderate";
  scalerGpu: number | null;
  definitionGpu: number;
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
  graph: ContentAddressedReleaseGraph;
}

interface NativeReleaseCatalog {
  ingredientDefinitions: IngredientDefinition[];
  recipes: RecipeSpecification[];
  recipeRuleDocument: { global_exclude?: string[]; commodities: RecipeCommodityRule[] };
  recipeExtensions: { commodities: RecipeCommodityRule[] };
  recipeAliases: Record<string, string>;
  knownWrong: KnownWrongDocument;
  recipeCatalogHash: string;
  ingredientCatalogHash: string;
  recipePricingConfigurationHash: string;
  conversionPolicy: IngredientConversionPolicy;
  conversionPolicyHash: string;
  conversionRegistryHash: string;
  conversionRegistry: Map<string, IngredientConversionEntry>;
  conversionRegistryEntries: number;
}

export async function loadNativeReleaseCatalog(incomeRoot: string): Promise<NativeReleaseCatalog> {
  const recipeDirectory = path.join(incomeRoot, "meal-prep", "db", "recipes");
  const configRoot = path.join(incomeRoot, "platform", "config");
  const [ingredientBytes, recipeNames, recipeRuleBytes, recipeExtensionBytes, aliasBytes, knownWrongBytes, conversionPolicyBytes] = await Promise.all([
    readFile(path.join(incomeRoot, "meal-prep", "db", "ingredients.json"), "utf8"),
    readdir(recipeDirectory),
    readFile(path.join(configRoot, "recipe-commodities.json"), "utf8"),
    readFile(path.join(configRoot, "recipe-commodity-extensions.json"), "utf8"),
    readFile(path.join(configRoot, "recipe-commodity-aliases.json"), "utf8"),
    readFile(path.join(configRoot, "known-wrong.json"), "utf8"),
    readFile(path.join(configRoot, "ingredient-conversion-policy.json"), "utf8"),
  ]);
  const ingredientDefinitions = JSON.parse(ingredientBytes.replace(/^\uFEFF/, "")) as IngredientDefinition[];
  const ingredientKeys = new Set<string>();
  for (const definition of ingredientDefinitions) {
    const normalized = key(definition.item);
    if (ingredientKeys.has(normalized)) {
      throw new Error(`ingredient catalog contains a duplicate normalized item: ${definition.item}`);
    }
    ingredientKeys.add(normalized);
  }
  const recipes = (await Promise.all(recipeNames.filter((name) => name.endsWith(".json")).sort().map(async (name) =>
    JSON.parse((await readFile(path.join(recipeDirectory, name), "utf8")).replace(/^\uFEFF/, "")) as RecipeSpecification,
  ))).sort((left, right) => left.slug.localeCompare(right.slug));
  const recipeRuleDocument = JSON.parse(recipeRuleBytes.replace(/^\uFEFF/, "")) as NativeReleaseCatalog["recipeRuleDocument"];
  const recipeExtensions = JSON.parse(recipeExtensionBytes.replace(/^\uFEFF/, "")) as NativeReleaseCatalog["recipeExtensions"];
  const recipeAliases = JSON.parse(aliasBytes.replace(/^\uFEFF/, "")) as Record<string, string>;
  const knownWrong = JSON.parse(knownWrongBytes.replace(/^\uFEFF/, "")) as KnownWrongDocument;
  const conversionPolicy = JSON.parse(conversionPolicyBytes.replace(/^\uFEFF/, "")) as IngredientConversionPolicy;
  if (conversionPolicy.version !== 1 || !Number.isFinite(conversionPolicy.requirements?.maximumExceptionRatio)) throw new Error("ingredient conversion policy is invalid");
  const definitionByName = new Map(ingredientDefinitions.map((definition) => [key(definition.item), definition]));
  const conversionEntries: IngredientConversionEntry[] = [];
  for (const recipe of recipes) {
    const scalerByName = new Map((recipe.scaler?.ing ?? []).map((item) => [key(item.item), item]));
    for (const ingredient of recipe.ingredients_grams ?? []) {
      const scaler = scalerByName.get(key(ingredient.item));
      const canonicalIngredientKey = key(scaler?.canon ?? ingredient.item);
      const definition = definitionByName.get(canonicalIngredientKey) ?? definitionByName.get(key(ingredient.item));
      const definitionGpu = asNumber(definition?.gpu);
      const scalerGpu = asNumber(scaler?.gpu);
      if (!definitionGpu) {
        if (scalerGpu) throw new Error(`conversion registry has a scaler GPU without an ingredient-definition authority for ${recipe.slug}/${ingredient.item}`);
        continue;
      }
      if (scalerGpu && Math.max(scalerGpu / definitionGpu, definitionGpu / scalerGpu) > conversionPolicy.requirements.maximumExceptionRatio) {
        throw new Error(`conversion registry exception exceeds policy ratio for ${recipe.slug}/${ingredient.item}`);
      }
      const exception = scalerGpu !== undefined && Math.abs(scalerGpu - definitionGpu) > 1e-9;
      conversionEntries.push({
        recipeSlug: recipe.slug, ingredientKey: key(ingredient.item), canonicalIngredientKey,
        gramsPerBasisUnit: exception ? scalerGpu! : definitionGpu,
        source: exception ? "recipe-scaler-exception" : "ingredient-definition",
        confidence: "moderate", scalerGpu: scalerGpu ?? null, definitionGpu,
      });
    }
  }
  conversionEntries.sort((left, right) => left.recipeSlug.localeCompare(right.recipeSlug) || left.ingredientKey.localeCompare(right.ingredientKey));
  const conversionRegistryHash = await digestHex(stableJson({ policy: conversionPolicy, entries: conversionEntries }));
  const conversionRegistry = new Map(conversionEntries.map((entry) => [`${entry.recipeSlug}|${entry.ingredientKey}`, entry]));
  return {
    ingredientDefinitions,
    recipes,
    recipeRuleDocument,
    recipeExtensions,
    recipeAliases,
    knownWrong,
    recipeCatalogHash: await digestHex(stableJson(recipes)),
    ingredientCatalogHash: await digestHex(stableJson(ingredientDefinitions)),
    recipePricingConfigurationHash: await digestHex(stableJson({ recipeRuleDocument, recipeExtensions, recipeAliases })),
    conversionPolicy,
    conversionPolicyHash: await digestHex(stableJson(conversionPolicy)),
    conversionRegistryHash,
    conversionRegistry,
    conversionRegistryEntries: conversionEntries.length,
  };
}

export async function nativeReleaseIdentity(
  snapshot: Pick<NativeEngineSnapshot, "mode" | "observedAt" | "configurationId" | "inputHash" | "inputBatchIds">,
  catalog: NativeReleaseCatalog,
) {
  const generatedAt = snapshot.observedAt;
  const weekOf = generatedAt.slice(0, 10);
  const inputBatchIds = [...snapshot.inputBatchIds].sort();
  const inputManifest = {
    kind: "native-v3-release",
    engineVersion: "native-v4.0.2-checkout-optimized-scenarios",
    marketId: "omaha",
    mode: "direct",
    releaseDate: weekOf,
    configurationId: snapshot.configurationId,
    engineSnapshotHash: snapshot.inputHash,
    recipeCatalogHash: catalog.recipeCatalogHash,
    ingredientCatalogHash: catalog.ingredientCatalogHash,
    recipePricingConfigurationHash: catalog.recipePricingConfigurationHash,
    ingredientConversionRegistry: {
      version: catalog.conversionPolicy.version,
      contentHash: catalog.conversionRegistryHash,
      policyHash: catalog.conversionPolicyHash,
      entryCount: catalog.conversionRegistryEntries,
      authority: catalog.conversionPolicy.authority,
    },
  };
  const inputHash = await digestHex(stableJson({ inputManifest, inputBatchIds }));
  return { generatedAt, weekOf, inputBatchIds, inputManifest, inputHash, releaseId: `rel_native_${inputHash.slice(0, 20)}` };
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

export async function buildNativeRelease(
  incomeRoot: string,
  snapshot: NativeEngineSnapshot,
  suppliedCatalog?: NativeReleaseCatalog,
  previousGraph?: ContentAddressedReleaseGraph,
): Promise<NativeReleaseArtifact> {
  if (snapshot.mode !== "direct") throw new Error("native publication requires a direct-only immutable engine snapshot");
  const catalog = suppliedCatalog ?? await loadNativeReleaseCatalog(incomeRoot);
  const { ingredientDefinitions, recipes, recipeRuleDocument, recipeExtensions, recipeAliases, knownWrong } = catalog;
  // Narrow recipe extensions precede broad legacy rules and carry their own
  // explicit exclusions, so they do not inherit the legacy global filter.
  const extensionIds = new Set(recipeExtensions.commodities.map((rule) => rule.id));
  const recipeRules = [...recipeExtensions.commodities, ...recipeRuleDocument.commodities];
  const recipeRuleIds = new Set(recipeRules.map((rule) => rule.id));
  const { generatedAt, weekOf, inputBatchIds, inputManifest, inputHash, releaseId } = await nativeReleaseIdentity(snapshot, catalog);

  const previousCells = new Map((previousGraph?.nodes ?? []).filter((item) => item.kind === "cell").map((item) => [item.key, item]));
  const rawCandidateById = new Map(snapshot.candidates.map((candidate) => [candidate.observation_id, candidate]));
  const nativeCells: NativeReleaseCell[] = [];
  let incrementallyReusedCells = 0;
  for (const commodity of snapshot.commodities) {
    const dependencyHash = await digestHex(stableJson({
      version: "commodity-store-cell-dag-v1", weekOf, configurationId: snapshot.configurationId, commodity,
      candidates: snapshot.candidates.filter((candidate) => candidate.commodity_id === commodity.id).map((candidate) => ({
        observationId: candidate.observation_id, storeLocationId: candidate.store_location_id,
        perUnitMicros: candidate.per_unit_micros, basisUnit: candidate.normalized_basis_unit,
        basisOptions: candidate.basis_options_json ?? null, capturedAt: candidate.captured_at,
        validTo: candidate.valid_to, coverageMode: candidate.coverage_mode, capturedTo: candidate.captured_to,
        knownWrong: candidate.known_wrong, maxAgeDays: candidate.max_age_days ?? null,
        name: candidate.name ?? null, sizeText: candidate.size_text ?? null,
      })),
    }));
    const prior = snapshot.stores.map((store) => previousCells.get(`${commodity.id}\u001f${store.id}`));
    const reusable = prior.every((item) => item?.dependencyHash === dependencyHash && item.payload && typeof item.payload === "object" && !Array.isArray(item.payload));
    if (reusable) {
      for (const item of prior) {
        const payload = item!.payload as NativeReleaseArtifact["cells"][number];
        nativeCells.push({
          commodityId: payload.commodityId, storeLocationId: payload.storeLocationId,
          observationId: payload.observationId ?? null, status: payload.status === "priced" ? "priced" : "missing",
          isCrown: payload.isCrown, displayPerUnitMicros: payload.displayPerUnitMicros ?? null,
          displayUnit: payload.displayUnit ?? null,
          winner: payload.observationId ? rawCandidateById.get(payload.observationId) ?? null : null,
          reason: { ...payload.reason, incrementalDependencyHash: dependencyHash, incrementallyReused: true },
        });
        incrementallyReusedCells += 1;
      }
      continue;
    }
    for (const cell of buildNativeCells({ ...snapshot, commodities: [commodity] })) {
      nativeCells.push({ ...cell, reason: { ...cell.reason, incrementalDependencyHash: dependencyHash } });
    }
  }
  const cells = nativeCells.map(publicCell);
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
  const recipeCrownByCommodity = new Map<string, PricedRecipeOption>();
  const recipeOptionsByCommodity = new Map<string, PricedRecipeOption[]>();
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
        sourceIdentityConflict: sourceNativeSizeConflict(candidate.raw.name, candidate.raw.size_text),
      })), generatedAt).winner;
      if (!selected) continue;
      const raw = rawByObservation.get(selected.observationId);
      if (!raw) throw new Error(`recipe winner ${selected.observationId} is absent from its immutable raw snapshot`);
      storeWinners.push({ commodityId: rule.id, storeLocationId, observationId: selected.observationId, displayPerUnitMicros: selected.perUnitMicros, displayUnit: apiUnit(rule.unit), raw });
    }
    const crown = storeWinners.sort((left, right) => left.displayPerUnitMicros - right.displayPerUnitMicros || left.storeLocationId.localeCompare(right.storeLocationId))[0];
    recipeOptionsByCommodity.set(rule.id, storeWinners);
    if (crown) recipeCrownByCommodity.set(rule.id, crown);
  }

  const boardOptionsByCommodity = new Map<string, PricedRecipeOption[]>();
  for (const cell of nativeCells.filter((item) => item.status === "priced" && item.winner && item.displayPerUnitMicros !== null && item.displayUnit)) {
    const options = boardOptionsByCommodity.get(cell.commodityId) ?? [];
    options.push({ commodityId: cell.commodityId, storeLocationId: cell.storeLocationId, observationId: cell.observationId!, displayPerUnitMicros: cell.displayPerUnitMicros!, displayUnit: cell.displayUnit!, raw: cell.winner! });
    boardOptionsByCommodity.set(cell.commodityId, options);
  }

  const optionCosts = (option: PricedRecipeOption, requiredBasisUnits: number) => {
    const utilizedMinor = moneyMinor(option.displayPerUnitMicros, requiredBasisUnits);
    const purchasePriceMinor = option.raw.purchase_price_minor;
    if (!purchasePriceMinor || purchasePriceMinor <= 0) return { utilizedMinor, checkoutMinor: utilizedMinor, packages: 0, variableWeight: true, packageBasisUnits: null };
    const packageBasisUnits = purchasePriceMinor * 10_000 / option.displayPerUnitMicros;
    const rawSize = option.raw.size_text?.trim().toLowerCase() ?? "";
    const variableWeight = ((option.raw.normalized_basis_qty_micros ?? 0) === 1_000_000 && ["lb", "per lb", "oz", "per oz"].includes(rawSize)) || /\bpriced\s+per\s+(?:pound|lb|oz)\b/i.test(option.raw.name ?? "");
    const packages = variableWeight ? 0 : Math.max(1, Math.ceil(requiredBasisUnits / packageBasisUnits - 1e-9));
    return { utilizedMinor, checkoutMinor: variableWeight ? utilizedMinor : purchasePriceMinor * packages, packages, variableWeight, packageBasisUnits };
  };

  const recipeCosts: RecipeCost[] = [];
  const recipePayload: Array<Record<string, unknown>> = [];
  const previousRecipes = new Map((previousGraph?.nodes ?? []).filter((item) => item.kind === "recipe").map((item) => [item.key, item]));
  const appendRecipePayload = (recipe: RecipeSpecification, cost: RecipeCost) => {
    recipePayload.push({
      slug: recipe.slug, name: recipe.name, protein: recipe.protein ?? null, visibility: recipe.visibility ?? "paid",
      servings: recipe.servings, calories: recipe.stat?.cal ?? null, status: cost.status,
      servingCostMinor: cost.servingCostMinor ?? null, batchCostMinor: cost.batchCostMinor ?? null,
      utilizedBatchCostMinor: cost.detail.utilizedBatchCostMinor ?? null,
      splitStoreCheckoutCostMinor: cost.detail.splitStoreCheckoutCostMinor ?? null,
      nonMemberSplitStoreCheckoutCostMinor: cost.detail.nonMemberSplitStoreCheckoutCostMinor ?? null,
      nonMemberUtilizedBatchCostMinor: cost.detail.nonMemberUtilizedBatchCostMinor ?? null,
      nonMemberServingCostMinor: cost.detail.nonMemberServingCostMinor ?? null,
      bestSingleStoreCheckoutCostMinor: cost.detail.bestSingleStoreCheckoutCostMinor ?? null,
      bestSingleStore: cost.detail.bestSingleStore ?? null,
      bestNonMemberSingleStoreCheckoutCostMinor: cost.detail.bestNonMemberSingleStoreCheckoutCostMinor ?? null,
      bestNonMemberSingleStore: cost.detail.bestNonMemberSingleStore ?? null,
      scenarios: cost.detail.scenarios,
      missingIngredients: cost.missingIngredients,
    });
  };
  const missingFrequency = new Map<string, number>();
  let incrementallyReusedRecipes = 0;
  for (const recipe of recipes) {
    const scalerByName = new Map((recipe.scaler?.ing ?? []).map((item) => [key(item.item), item]));
    const resolveCommodity = (ingredient: RecipeIngredient) => {
      const scaler = scalerByName.get(key(ingredient.item));
      const definition = ingredientByName.get(key(scaler?.canon ?? ingredient.item)) ?? ingredientByName.get(key(ingredient.item));
      const requestedBids = [...new Set([scaler?.bid, definition?.bid].filter((value): value is string => Boolean(value)))];
      const aliasedBids = requestedBids.map((bid) => recipeAliases[bid]).filter((bid): bid is string => Boolean(bid));
      return requestedBids.find((bid) => commodityById.has(bid) || recipeRuleIds.has(bid))
        ?? aliasedBids.find((bid) => commodityById.has(bid) || recipeRuleIds.has(bid))
        ?? commodityByLabel.get(key(scaler?.canon ?? ingredient.item));
    };
    const incrementalDependencyHash = await digestHex(stableJson({
      version: "recipe-cost-dag-v2-checkout-optimized", recipe, configurationId: snapshot.configurationId,
      pricingConfigurationHash: catalog.recipePricingConfigurationHash,
      conversionRegistryHash: catalog.conversionRegistryHash,
      ingredients: (recipe.ingredients_grams ?? []).map((ingredient) => {
        const commodityId = resolveCommodity(ingredient);
        return {
          item: ingredient.item, grams: ingredient.grams, commodityId: commodityId ?? null,
          conversion: catalog.conversionRegistry.get(`${recipe.slug}|${key(ingredient.item)}`) ?? null,
          options: (commodityId ? (boardOptionsByCommodity.get(commodityId) ?? recipeOptionsByCommodity.get(commodityId) ?? []) : []).map((option) => ({
            observationId: option.observationId, storeLocationId: option.storeLocationId,
            displayPerUnitMicros: option.displayPerUnitMicros, displayUnit: option.displayUnit,
            purchasePriceMinor: option.raw.purchase_price_minor ?? null, regularPriceMinor: option.raw.regular_price_minor ?? null,
            kind: option.raw.kind ?? null, membershipRequired: option.raw.membership_required ?? 0,
            loyaltyRequired: option.raw.loyalty_required ?? 0, sizeText: option.raw.size_text ?? null,
          })),
        };
      }),
    }));
    const previous = previousRecipes.get(recipe.slug);
    if (previous?.dependencyHash === incrementalDependencyHash && previous.payload && typeof previous.payload === "object" && !Array.isArray(previous.payload)) {
      const reused = previous.payload as RecipeCost;
      if (reused.recipeSlug === recipe.slug && (reused.status === "complete" || reused.status === "incomplete" || reused.status === "held")) {
        recipeCosts.push(reused);
        appendRecipePayload(recipe, reused);
        incrementallyReusedRecipes += 1;
        continue;
      }
    }
    const ingredientDetails: Array<Record<string, unknown>> = [];
    const missingIngredients: string[] = [];
    let utilizedBatchMinor = 0;
    let splitStoreCheckoutMinor = 0;
    let nonMemberSplitStoreCheckoutMinor = 0;
    let nonMemberUtilizedBatchMinor = 0;
    let nonMemberMissing = false;
    let everydayBaselineCheckoutMinor = 0;
    let everydayBaselineUtilizedMinor = 0;
    let everydayMissing = false;
    const singleStoreCheckout = new Map(snapshot.stores.map((store) => [store.id, { total: 0, missing: [] as string[] }]));
    const nonMemberSingleStoreCheckout = new Map(snapshot.stores.filter((store) => store.membership_required !== 1).map((store) => [store.id, { total: 0, missing: [] as string[] }]));
    for (const ingredient of recipe.ingredients_grams ?? []) {
      const scaler = scalerByName.get(key(ingredient.item));
      const definition = ingredientByName.get(key(scaler?.canon ?? ingredient.item)) ?? ingredientByName.get(key(ingredient.item));
      const commodityId = resolveCommodity(ingredient);
      const conversion = catalog.conversionRegistry.get(`${recipe.slug}|${key(ingredient.item)}`);
      const gpu = conversion?.gramsPerBasisUnit;
      const grams = asNumber(ingredient.grams);
      const options = commodityId ? (boardOptionsByCommodity.get(commodityId) ?? recipeOptionsByCommodity.get(commodityId) ?? []) : [];
      const crown = [...options].sort((left, right) => left.displayPerUnitMicros - right.displayPerUnitMicros || left.storeLocationId.localeCompare(right.storeLocationId))[0];
      const nonMemberOptions = options.filter((option) => option.raw.membership_required !== 1 && option.raw.loyalty_required !== 1 && storeById.get(option.storeLocationId)?.membership_required !== 1);
      const everydayOptions = options.flatMap((option) => {
        const purchase = option.raw.purchase_price_minor ?? 0;
        const regular = option.raw.regular_price_minor ?? (option.raw.kind === "everyday" ? purchase : 0);
        if (purchase <= 0 || regular <= 0 || option.raw.membership_required === 1 || option.raw.loyalty_required === 1
          || storeById.get(option.storeLocationId)?.membership_required === 1) return [];
        return [{ ...option, displayPerUnitMicros: Math.round(option.displayPerUnitMicros * regular / purchase), raw: { ...option.raw, purchase_price_minor: regular } }];
      });
      const missing: string[] = [];
      if (!commodityId) missing.push("commodity-mapping");
      if (!gpu) missing.push("grams-per-basis-unit");
      if (!grams) missing.push("ingredient-grams");
      if (!crown) missing.push("priced-release-cell");
      if (missing.length > 0) {
        for (const accumulator of [...singleStoreCheckout.values(), ...nonMemberSingleStoreCheckout.values()]) accumulator.missing.push(ingredient.item);
        missingIngredients.push(ingredient.item);
        missingFrequency.set(`${ingredient.item}: ${missing.join(",")}`, (missingFrequency.get(`${ingredient.item}: ${missing.join(",")}`) ?? 0) + 1);
        ingredientDetails.push({ item: ingredient.item, grams: ingredient.grams, commodityId: commodityId ?? null, status: "missing", reasons: missing });
        continue;
      }
      const requiredBasisUnits = grams! / gpu!;
      const utilizedCosts = optionCosts(crown!, requiredBasisUnits);
      const checkoutChoices = options.map((option) => ({ option, costs: optionCosts(option, requiredBasisUnits) }))
        .sort((left, right) => left.costs.checkoutMinor - right.costs.checkoutMinor
          || left.option.displayPerUnitMicros - right.option.displayPerUnitMicros
          || left.option.storeLocationId.localeCompare(right.option.storeLocationId));
      const checkout = checkoutChoices[0]!;
      const nonMemberUtilized = [...nonMemberOptions].sort((left, right) => left.displayPerUnitMicros - right.displayPerUnitMicros || left.storeLocationId.localeCompare(right.storeLocationId))[0];
      const nonMemberCheckout = nonMemberOptions.map((option) => ({ option, costs: optionCosts(option, requiredBasisUnits) }))
        .sort((left, right) => left.costs.checkoutMinor - right.costs.checkoutMinor
          || left.option.displayPerUnitMicros - right.option.displayPerUnitMicros
          || left.option.storeLocationId.localeCompare(right.option.storeLocationId))[0];
      const everydayUtilized = [...everydayOptions].sort((left, right) => left.displayPerUnitMicros - right.displayPerUnitMicros || left.storeLocationId.localeCompare(right.storeLocationId))[0];
      const everydayCheckout = everydayOptions.map((option) => ({ option, costs: optionCosts(option, requiredBasisUnits) }))
        .sort((left, right) => left.costs.checkoutMinor - right.costs.checkoutMinor
          || left.option.displayPerUnitMicros - right.option.displayPerUnitMicros
          || left.option.storeLocationId.localeCompare(right.option.storeLocationId))[0];
      utilizedBatchMinor += utilizedCosts.utilizedMinor;
      splitStoreCheckoutMinor += checkout.costs.checkoutMinor;
      if (nonMemberCheckout && nonMemberUtilized) {
        nonMemberSplitStoreCheckoutMinor += nonMemberCheckout.costs.checkoutMinor;
        nonMemberUtilizedBatchMinor += optionCosts(nonMemberUtilized, requiredBasisUnits).utilizedMinor;
      }
      else nonMemberMissing = true;
      if (everydayCheckout && everydayUtilized) {
        everydayBaselineCheckoutMinor += everydayCheckout.costs.checkoutMinor;
        everydayBaselineUtilizedMinor += optionCosts(everydayUtilized, requiredBasisUnits).utilizedMinor;
      } else everydayMissing = true;
      for (const [storeId, accumulator] of singleStoreCheckout) {
        const storeOption = options.find((option) => option.storeLocationId === storeId);
        if (!storeOption) accumulator.missing.push(ingredient.item);
        else accumulator.total += optionCosts(storeOption, requiredBasisUnits).checkoutMinor;
      }
      for (const [storeId, accumulator] of nonMemberSingleStoreCheckout) {
        const storeOption = nonMemberOptions.find((option) => option.storeLocationId === storeId);
        if (!storeOption) accumulator.missing.push(ingredient.item);
        else accumulator.total += optionCosts(storeOption, requiredBasisUnits).checkoutMinor;
      }
      ingredientDetails.push({
        item: ingredient.item,
        grams: grams!,
        commodityId: commodityId!,
        observationId: checkout.option.observationId,
        store: storeById.get(checkout.option.storeLocationId)?.store_name ?? checkout.option.storeLocationId,
        perUnitMicros: checkout.option.displayPerUnitMicros,
        basisUnit: checkout.option.displayUnit,
        gpu: gpu!,
        gpuSource: conversion?.source === "recipe-scaler-exception" ? "recipe-scaler" : "ingredient-definition",
        scalerGpu: asNumber(scaler?.gpu) ?? null,
        definitionGpu: asNumber(definition?.gpu) ?? null,
        conversionId: `${catalog.conversionRegistryHash.slice(0, 16)}:${recipe.slug}:${key(ingredient.item).replace(/[^a-z0-9]+/g, "-")}`,
        conversionRegistryHash: catalog.conversionRegistryHash,
        conversionSource: conversion!.source,
        conversionConfidence: conversion!.confidence,
        utilizedObservationId: crown!.observationId,
        utilizedStoreLocationId: crown!.storeLocationId,
        utilizedPerUnitMicros: crown!.displayPerUnitMicros,
        utilizedCostMinor: utilizedCosts.utilizedMinor,
        purchaseCostMinor: checkout.costs.checkoutMinor,
        packageCount: checkout.costs.packages,
        variableWeight: checkout.costs.variableWeight,
        packageBasisUnits: checkout.costs.packageBasisUnits,
        sourcePurchasePriceMinor: checkout.option.raw.purchase_price_minor ?? null,
        sourceNormalizedBasisUnit: checkout.option.raw.normalized_basis_unit,
        sourceNormalizedBasisQtyMicros: checkout.option.raw.normalized_basis_qty_micros ?? null,
        membershipRequired: checkout.option.raw.membership_required === 1 || storeById.get(checkout.option.storeLocationId)?.membership_required === 1,
        loyaltyRequired: checkout.option.raw.loyalty_required === 1,
        nonMemberObservationId: nonMemberCheckout?.option.observationId ?? null,
        nonMemberPurchaseCostMinor: nonMemberCheckout?.costs.checkoutMinor ?? null,
        nonMemberUtilizedCostMinor: nonMemberUtilized ? optionCosts(nonMemberUtilized, requiredBasisUnits).utilizedMinor : null,
        everydayObservationId: everydayCheckout?.option.observationId ?? null,
        everydayStoreLocationId: everydayCheckout?.option.storeLocationId ?? null,
        everydayPerUnitMicros: everydayCheckout?.option.displayPerUnitMicros ?? null,
        everydayPurchaseCostMinor: everydayCheckout?.costs.checkoutMinor ?? null,
        everydaySourcePurchasePriceMinor: everydayCheckout?.option.raw.purchase_price_minor ?? null,
        everydayPackageBasisUnits: everydayCheckout?.costs.packageBasisUnits ?? null,
        everydayVariableWeight: everydayCheckout?.costs.variableWeight ?? null,
        storeOptions: Object.fromEntries(options.map((option) => {
          const optionCost = optionCosts(option, requiredBasisUnits);
          return [option.storeLocationId, {
            store: storeById.get(option.storeLocationId)?.store_name ?? option.storeLocationId,
            observationId: option.observationId, perUnitMicros: option.displayPerUnitMicros,
            purchasePriceMinor: option.raw.purchase_price_minor ?? null,
            packageBasisUnits: optionCost.packageBasisUnits, variableWeight: optionCost.variableWeight,
            membershipRequired: option.raw.membership_required === 1 || storeById.get(option.storeLocationId)?.membership_required === 1,
            loyaltyRequired: option.raw.loyalty_required === 1,
          }];
        })),
        packageLabel: definition?.bulk ? definition?.pantry_pkg_label : definition?.buy_pkg_label,
        pantry: Boolean(definition!.bulk),
        status: "priced",
      });
    }
    const complete = missingIngredients.length === 0 && (recipe.ingredients_grams?.length ?? 0) > 0;
    const servingCostMinor = complete ? Math.round(utilizedBatchMinor / recipe.servings) : undefined;
    const completeSingleStores = [...singleStoreCheckout.entries()].filter(([, value]) => value.missing.length === 0).sort((left, right) => left[1].total - right[1].total || left[0].localeCompare(right[0]));
    const bestSingleStore = completeSingleStores[0];
    const completeNonMemberSingleStores = [...nonMemberSingleStoreCheckout.entries()].filter(([, value]) => value.missing.length === 0).sort((left, right) => left[1].total - right[1].total || left[0].localeCompare(right[0]));
    const bestNonMemberSingleStore = completeNonMemberSingleStores[0];
    const scenarios = {
      utilized: {
        status: complete ? "complete" : "incomplete", batchCostMinor: complete ? utilizedBatchMinor : null,
        servingCostMinor: complete ? Math.round(utilizedBatchMinor / recipe.servings) : null,
        missingIngredients: [...new Set(missingIngredients)].sort(),
      },
      registerCheckout: {
        status: complete ? "complete" : "incomplete", batchCostMinor: complete ? splitStoreCheckoutMinor : null,
        servingCostMinor: complete ? Math.round(splitStoreCheckoutMinor / recipe.servings) : null,
        missingIngredients: [...new Set(missingIngredients)].sort(),
      },
      nonMemberCheckout: {
        status: complete && !nonMemberMissing ? "complete" : "incomplete",
        batchCostMinor: complete && !nonMemberMissing ? nonMemberSplitStoreCheckoutMinor : null,
        servingCostMinor: complete && !nonMemberMissing ? Math.round(nonMemberSplitStoreCheckoutMinor / recipe.servings) : null,
        missingIngredients: nonMemberMissing ? ["non-member price unavailable"] : [...new Set(missingIngredients)].sort(),
      },
      everydayBaseline: {
        status: complete && !everydayMissing ? "complete" : "incomplete",
        batchCostMinor: complete && !everydayMissing ? everydayBaselineCheckoutMinor : null,
        utilizedBatchCostMinor: complete && !everydayMissing ? everydayBaselineUtilizedMinor : null,
        servingCostMinor: complete && !everydayMissing ? Math.round(everydayBaselineCheckoutMinor / recipe.servings) : null,
        missingIngredients: everydayMissing ? ["everyday non-promotional price unavailable"] : [...new Set(missingIngredients)].sort(),
      },
      selectedStoreCheckout: Object.fromEntries([...singleStoreCheckout].map(([storeId, value]) => [storeId, {
        storeLocationId: storeId, store: storeById.get(storeId)?.store_name ?? storeId,
        status: value.missing.length === 0 ? "complete" : "incomplete",
        batchCostMinor: value.missing.length === 0 ? value.total : null,
        servingCostMinor: value.missing.length === 0 ? Math.round(value.total / recipe.servings) : null,
        missingIngredients: [...new Set(value.missing)].sort(),
      }])),
    };
    const cost: RecipeCost = {
      recipeSlug: recipe.slug,
      status: complete ? "complete" : "incomplete",
      ...(complete ? { batchCostMinor: utilizedBatchMinor, servingCostMinor } : {}),
      servings: recipe.servings,
      missingIngredients: [...new Set(missingIngredients)].sort(),
      detail: {
        pricingAuthority: "native-release-crowns",
        protein: recipe.protein ?? null,
        calories: recipe.stat?.cal ?? null,
        utilizedBatchCostMinor: utilizedBatchMinor,
        utilizedServingCostMinor: Math.round(utilizedBatchMinor / recipe.servings),
        splitStoreCheckoutCostMinor: complete ? splitStoreCheckoutMinor : null,
        nonMemberSplitStoreCheckoutCostMinor: complete && !nonMemberMissing ? nonMemberSplitStoreCheckoutMinor : null,
        nonMemberUtilizedBatchCostMinor: complete && !nonMemberMissing ? nonMemberUtilizedBatchMinor : null,
        nonMemberServingCostMinor: complete && !nonMemberMissing ? Math.round(nonMemberUtilizedBatchMinor / recipe.servings) : null,
        bestSingleStoreCheckoutCostMinor: complete && bestSingleStore ? bestSingleStore[1].total : null,
        bestSingleStoreLocationId: complete && bestSingleStore ? bestSingleStore[0] : null,
        bestSingleStore: complete && bestSingleStore ? storeById.get(bestSingleStore[0])?.store_name ?? bestSingleStore[0] : null,
        bestNonMemberSingleStoreCheckoutCostMinor: complete && bestNonMemberSingleStore ? bestNonMemberSingleStore[1].total : null,
        bestNonMemberSingleStoreLocationId: complete && bestNonMemberSingleStore ? bestNonMemberSingleStore[0] : null,
        bestNonMemberSingleStore: complete && bestNonMemberSingleStore ? storeById.get(bestNonMemberSingleStore[0])?.store_name ?? bestNonMemberSingleStore[0] : null,
        singleStoreCoverage: Object.fromEntries([...singleStoreCheckout].map(([storeId, value]) => [storeId, { checkoutCostMinor: value.missing.length === 0 ? value.total : null, missingIngredients: value.missing }])),
        scenarios,
        incrementalDependencyHash,
        pantryAddMinor: complete ? Math.max(0, splitStoreCheckoutMinor - utilizedBatchMinor) : null,
        firstRunMinor: complete ? splitStoreCheckoutMinor : null,
        ingredientCount: recipe.ingredients_grams?.length ?? 0,
        ingredients: ingredientDetails,
      },
    };
    recipeCosts.push(cost);
    appendRecipePayload(recipe, cost);
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
      observationId: cell.observationId!,
      perUnitMicros: cell.displayPerUnitMicros,
      unit: cell.displayUnit,
      membership: cell.winner!.membership_required === 1 || storeById.get(cell.storeLocationId)?.membership_required === 1,
      member_label: cell.winner!.loyalty_required === 1 ? "Loyalty price" : cell.winner!.membership_required === 1 || storeById.get(cell.storeLocationId)?.membership_required === 1 ? "Membership required" : "",
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
  const feedIngredients: Record<string, Record<string, unknown>> = Object.fromEntries(boardCommodities.filter((commodity) => commodity.cheapest).map((commodity) => [commodity.id, {
    unit: commodity.unit === "fl_oz" ? "floz" : commodity.unit,
    cheapest: commodity.cheapest!.perUnitMicros! / 1_000_000,
    store: commodity.cheapest!.store,
    type: "everyday",
    url: commodity.stores.find((store) => store.storeLocationId === commodity.cheapest!.storeLocationId)?.productUrl ?? "",
    n: commodity.stores.length,
    stores: Object.fromEntries(commodity.stores.map((store) => [store.store, store.perUnitMicros! / 1_000_000])),
  }]));
  for (const [alias, target] of Object.entries(recipeAliases)) {
    const ingredient = feedIngredients[target];
    if (!ingredient || feedIngredients[alias]) continue;
    feedIngredients[alias] = { ...ingredient, alias_of: target };
  }
  const feedRecipes = Object.fromEntries(recipePayload.filter((recipe) => recipe.status === "complete").map((recipe) => [String(recipe.slug), {
    name: recipe.name,
    servings: recipe.servings,
    week_cost: Number(((Number(recipe.batchCostMinor) || 0) / 100).toFixed(2)),
    per_serving: Number(((Number(recipe.servingCostMinor) || 0) / 100).toFixed(2)),
    utilized_batch_cost: Number(((Number(recipe.utilizedBatchCostMinor) || 0) / 100).toFixed(2)),
    split_store_checkout_cost: recipe.splitStoreCheckoutCostMinor === null ? null : Number((Number(recipe.splitStoreCheckoutCostMinor) / 100).toFixed(2)),
    non_member_split_store_checkout_cost: recipe.nonMemberSplitStoreCheckoutCostMinor === null ? null : Number((Number(recipe.nonMemberSplitStoreCheckoutCostMinor) / 100).toFixed(2)),
    non_member_utilized_batch_cost: recipe.nonMemberUtilizedBatchCostMinor === null ? null : Number((Number(recipe.nonMemberUtilizedBatchCostMinor) / 100).toFixed(2)),
    non_member_per_serving: recipe.nonMemberServingCostMinor === null ? null : Number((Number(recipe.nonMemberServingCostMinor) / 100).toFixed(2)),
    best_single_store_checkout_cost: recipe.bestSingleStoreCheckoutCostMinor === null ? null : Number((Number(recipe.bestSingleStoreCheckoutCostMinor) / 100).toFixed(2)),
    best_single_store: recipe.bestSingleStore,
    best_non_member_single_store_checkout_cost: recipe.bestNonMemberSingleStoreCheckoutCostMinor === null ? null : Number((Number(recipe.bestNonMemberSingleStoreCheckoutCostMinor) / 100).toFixed(2)),
    best_non_member_single_store: recipe.bestNonMemberSingleStore,
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
  const payloads = {
    board: boardPayload,
    feed: feedPayload,
    top5: top5Payload,
    free_rotation: rotationPayload,
    recipes: { version: 3, releaseId, generatedAt, recipes: recipePayload },
  };
  const graph = await buildContentAddressedReleaseGraph({
    parentReleaseId: snapshot.currentReleaseId || null, inputHash, configurationId: snapshot.configurationId,
    cells, recipeCosts, payloads, top5, freeRotation,
  });
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
    payloads,
    graph,
    audit: {
      mode: snapshot.mode,
      inputBatchCount: inputBatchIds.length,
      commodities: snapshot.commodities.length,
      stores: snapshot.stores.length,
      pricedCells: cells.filter((cell) => cell.status === "priced").length,
      missingCells: cells.filter((cell) => cell.status === "missing").length,
      incrementallyReusedCells,
      recalculatedCells: cells.length - incrementallyReusedCells,
      authoredRecipes: recipes.length,
      completeRecipes: recipeCosts.length - incomplete.length,
      incompleteRecipes: incomplete.length,
      incrementallyReusedRecipes,
      recalculatedRecipes: recipes.length - incrementallyReusedRecipes,
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
