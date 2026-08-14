import type {
  BrowserCaptureAccuracy,
  BrowserCaptureAccuracyRow,
  BrowserCaptureStore,
  BrowserCaptureTruth,
  BrowserCaptureVerification,
  ObservationInput,
  PriceSemantics,
  ProductIdentity,
} from "@thriftycrew/contracts";
import { CAPTURE_SEMANTICS_CUTOVER } from "@thriftycrew/contracts";

const encoder = new TextEncoder();

/** Normalize repository text before hashing so Windows and Linux checkouts agree. */
export function normalizeTextForHash(value: string): string {
  return value.replace(/\r\n?/g, "\n");
}

export function normalizeName(value: string): string {
  return value
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

export function expectedPerUnitMicros(priceMinor: number, normalizedBasisQtyMicros: number): number {
  if (!Number.isSafeInteger(priceMinor) || priceMinor < 0) throw new Error("priceMinor must be a non-negative safe integer");
  if (!Number.isSafeInteger(normalizedBasisQtyMicros) || normalizedBasisQtyMicros <= 0) {
    throw new Error("normalizedBasisQtyMicros must be a positive safe integer");
  }
  const result = Math.round((priceMinor * 10_000 * 1_000_000) / normalizedBasisQtyMicros);
  if (!Number.isSafeInteger(result)) throw new Error("normalized unit price exceeds safe integer range");
  return result;
}

export function assertObservationArithmetic(observation: ObservationInput, toleranceMicros = 2): void {
  const expected = expectedPerUnitMicros(observation.purchasePriceMinor, observation.normalizedBasisQtyMicros);
  if (Math.abs(expected - observation.perUnitMicros) > toleranceMicros) {
    throw new Error(`per-unit mismatch: received ${observation.perUnitMicros}, expected ${expected}`);
  }
  for (const option of observation.basisOptions ?? []) {
    const optionExpected = expectedPerUnitMicros(observation.purchasePriceMinor, option.quantityMicros);
    if (Math.abs(optionExpected - option.perUnitMicros) > toleranceMicros) {
      throw new Error(`basis-option mismatch (${option.source}): received ${option.perUnitMicros}, expected ${optionExpected}`);
    }
  }
}

export function stableJson(value: unknown): string {
  if (value === undefined) return "null";
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map((item) => item === undefined ? "null" : stableJson(item)).join(",")}]`;
  const object = value as Record<string, unknown>;
  return `{${Object.keys(object).filter((key) => object[key] !== undefined).sort().map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(",")}}`;
}

export async function digestHex(value: string | Uint8Array): Promise<string> {
  const bytes = typeof value === "string" ? encoder.encode(value) : value;
  const digest = await crypto.subtle.digest("SHA-256", Uint8Array.from(bytes).buffer);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function deterministicId(prefix: string, ...parts: string[]): Promise<string> {
  return `${prefix}_${(await digestHex(parts.join("\u001f"))).slice(0, 32)}`;
}

const INGREDIENT_NON_FOOD_PRODUCT = /\b(?:wax\s+melts?|candles?|incense|air\s+fresheners?|fragrance|perfumes?|eau\s+de\s+parfum|colognes?|potpourri|diffusers?|essential\s+oils?|soaps?|shampoos?|conditioners?|hair\s+(?:care|mask|treatment)|body\s+wash|cleansing\s+water|lotions?|moisturizers?|serums?|cosmetics?|makeup|eyeshadows?|pet\s+food|dog\s+treats?|cat\s+treats?|craft|decor)\b/i;

/** Shared fail-closed identity rules used by both producer ranking and independent QA. */
export function isClearlyNonFoodIngredientProduct(name: string, taxonomy = ""): boolean {
  return INGREDIENT_NON_FOOD_PRODUCT.test(`${name} ${taxonomy}`);
}

export function isClearlyIngredientDerivative(commodityId: string, name: string): boolean {
  if (/pistachios?/.test(commodityId)) {
    return /\b(?:frosting|muffins?|cakes?|cookies?|pudding|ice\s+cream|gelato|butter|cream|paste|spread|cereal|granola|chocolate|flavor(?:ed|ing)?)\b/i.test(name);
  }
  if (/green-chilli/.test(commodityId)) {
    return /\b(?:tomatoes?|salsa|sauces?|soups?|stews?|meals?|rice|beans?|queso|cheese|dips?|seasoning|diced|chopped|roasted)\b/i.test(name);
  }
  if (/(?:portobello|portabella)-mushrooms?/.test(commodityId)) {
    return /\b(?:pork|loin|filet|chicken|beef|steak)\b/i.test(name);
  }
  if (/saffron/.test(commodityId)) {
    return /\b(?:rice|tea|seasonings?|extract|supplements?|color(?:ing)?)\b/i.test(name);
  }
  return false;
}

function ingredientRegexes(patterns: string[]): RegExp[] {
  return patterns.map((pattern) => new RegExp(pattern.replace(/^\(\?i\)/, ""), "i"));
}

export function matchesIngredientCommodityExclusion(patterns: string[], productName: string, packageText = ""): boolean {
  if (ingredientRegexes(patterns).some((rule) => rule.test(productName))) return true;
  const joined = `${productName} ${packageText}`;
  return patterns.some((pattern) => {
    const normalized = pattern.toLowerCase().replace(/\\b|\\s\+|\(\?:|[()^$?+*|[\]{}]/g, " ").replace(/[^a-z]+/g, " ").trim();
    if (/\bcanned\b/.test(normalized) && /\b(?:can|cans|canned)\b/i.test(joined)) return true;
    if (/\bdried\b/.test(normalized) && /\b(?:dry|dried)\b/i.test(joined)) return true;
    return false;
  });
}

/**
 * Strip transport-only URL variation before a URL participates in durable
 * product identity. Retailer/CDN query strings routinely contain session,
 * tracking, resize, and cache-buster values which must not create versions.
 */
export function canonicalProductUrl(value: string | undefined): string | null {
  if (!value) return null;
  try {
    const url = new URL(value);
    url.hash = "";
    url.search = "";
    url.hostname = url.hostname.toLowerCase();
    url.pathname = url.pathname.replace(/\/{2,}/g, "/").replace(/\/$/, "") || "/";
    return url.toString();
  } catch {
    return value.trim() || null;
  }
}

export interface SemanticProductVersionInput {
  name: string;
  sizeText: string;
  productUrl?: string | undefined;
  taxonomyPath?: string | undefined;
  identity?: { brand?: string | undefined } | undefined;
}

/** Only fields whose meaning changed belong in a product-version hash. */
export function semanticProductVersion(input: SemanticProductVersionInput): Record<string, unknown> {
  return {
    name: normalizeName(input.name),
    sizeText: normalizeName(input.sizeText),
    brand: normalizeName(input.identity?.brand ?? ""),
    productUrl: canonicalProductUrl(input.productUrl),
    taxonomyPath: normalizeName(input.taxonomyPath ?? ""),
  };
}

export interface SemanticOfferInput {
  kind: string;
  currency: string;
  purchasePriceMinor: number;
  regularPriceMinor?: number | undefined;
  purchaseQuantity: number;
  packageCount: number;
  capturedBasisUnit: string;
  capturedBasisQtyMicros: number;
  normalizedBasisUnit: string;
  normalizedBasisQtyMicros: number;
  perUnitMicros: number;
  basisOptions?: unknown[] | undefined;
  loyaltyRequired: boolean;
  membershipRequired: boolean;
  rawPriceText: string;
  rawSizeText: string;
  validFrom?: string | undefined;
  validTo?: string | undefined;
  priceSemantics?: unknown;
  offerSnapshot?: object | undefined;
}

/**
 * The source-native offer fact. Capture time, term, evidence, raw index, and
 * other provenance live on batch membership and deliberately do not affect it.
 */
export function semanticOfferFact(input: SemanticOfferInput): Record<string, unknown> {
  const snapshot: Record<string, unknown> = input.offerSnapshot ? { ...input.offerSnapshot } : {};
  delete snapshot.observedAt;
  return {
    kind: input.kind,
    currency: input.currency,
    purchasePriceMinor: input.purchasePriceMinor,
    regularPriceMinor: input.regularPriceMinor ?? null,
    purchaseQuantity: input.purchaseQuantity,
    packageCount: input.packageCount,
    capturedBasisUnit: input.capturedBasisUnit,
    capturedBasisQtyMicros: input.capturedBasisQtyMicros,
    normalizedBasisUnit: input.normalizedBasisUnit,
    normalizedBasisQtyMicros: input.normalizedBasisQtyMicros,
    perUnitMicros: input.perUnitMicros,
    basisOptions: input.basisOptions ?? [],
    loyaltyRequired: input.loyaltyRequired,
    membershipRequired: input.membershipRequired,
    rawPriceText: input.rawPriceText.trim(),
    rawSizeText: input.rawSizeText.trim(),
    validFrom: input.validFrom ?? null,
    validTo: input.validTo ?? null,
    priceSemantics: input.priceSemantics ?? {},
    offerSnapshot: snapshot,
  };
}

export async function semanticObservationId(sourceId: string, productVersionId: string, input: SemanticOfferInput): Promise<{ id: string; hash: string }> {
  const hash = await digestHex(stableJson([sourceId, productVersionId, semanticOfferFact(input)]));
  return { id: `obs_${hash.slice(0, 32)}`, hash };
}

type CaptureAccuracyCandidate = Omit<BrowserCaptureAccuracyRow, "rowKey" | "discoveryHash" | "riskReasons" | "verificationRequired">;
type CaptureAccuracyTerm = { outcome: string; rowCount: number; retrieval: { targetResultCount: number; loadedResultCount: number; availableResultCount?: number | undefined; hasMoreResults: boolean; termination: string } };

const CAPTURE_QUERY_MODIFIERS = new Set([
  "and", "with", "for", "pack", "count", "each",
]);

function captureWordStem(word: string): string {
  if (word.length > 5 && word.endsWith("ies")) return `${word.slice(0, -3)}y`;
  if (word.length > 5 && word.endsWith("oes")) return word.slice(0, -2);
  if (word.length > 5 && word.endsWith("es")) return word.slice(0, -2);
  if (word.length > 4 && word.endsWith("s") && !word.endsWith("ss")) return word.slice(0, -1);
  return word;
}

function captureCandidateRelevanceScore(candidate: CaptureAccuracyCandidate): number {
  const queryTokens = normalizeName(candidate.query).split(" ")
    .filter((word) => word.length >= 3 && !CAPTURE_QUERY_MODIFIERS.has(word))
    .map(captureWordStem);
  if (queryTokens.length === 0) return 0;
  const candidateTokens = new Set(normalizeName(`${candidate.name} ${candidate.taxonomyPath ?? ""}`).split(" ").map(captureWordStem));
  return queryTokens.reduce((score, token) => score + Number(candidateTokens.has(token)), 0);
}

export function parseCapturePriceText(text: string): { unitPriceMinor: number; qualifyingQuantity: number; totalPriceMinor: number } | undefined {
  const normalized = text.toLowerCase().replace(/,/g, "").trim();
  const multi = normalized.match(/(?:^|\s)(\d+)\s*(?:\/|for)\s*\$?([0-9]+(?:\.[0-9]{1,2})?)(?=\s|$)/);
  if (multi) {
    const qualifyingQuantity = Number(multi[1]);
    const totalPriceMinor = Math.round(Number(multi[2]) * 100);
    if (!Number.isSafeInteger(qualifyingQuantity) || qualifyingQuantity <= 1 || !Number.isSafeInteger(totalPriceMinor)) return undefined;
    const unitPriceMinor = Math.round(totalPriceMinor / qualifyingQuantity);
    if (Math.abs(unitPriceMinor * qualifyingQuantity - totalPriceMinor) > 1) return undefined;
    return { unitPriceMinor, qualifyingQuantity, totalPriceMinor };
  }
  const prices = [...normalized.matchAll(/\$?([0-9]+(?:\.[0-9]{1,2})?)/g)]
    .filter((match) => match[0].includes("$") || /^\s*(?:current\s+price\s*:\s*)?\d+(?:\.\d{1,2})?\s*$/i.test(normalized));
  if (prices.length !== 1) return undefined;
  const unitPriceMinor = Math.round(Number(prices[0]![1]) * 100);
  return Number.isSafeInteger(unitPriceMinor) ? { unitPriceMinor, qualifyingQuantity: 1, totalPriceMinor: unitPriceMinor } : undefined;
}

export async function expectedProductIdentityFingerprint(identity: Omit<ProductIdentity, "fingerprint" | "confidence">, name: string, sizeText: string): Promise<string> {
  return digestHex(stableJson({
    retailerProductId: identity.retailerProductId ?? null,
    gtin: identity.gtin ?? null,
    upc: identity.upc ?? null,
    sku: identity.sku ?? null,
    canonicalUrl: identity.canonicalUrl ?? null,
    brand: normalizeName(identity.brand ?? ""),
    name: normalizeName(name),
    sizeText: normalizeName(sizeText),
  }));
}

export async function productIdentityPass(externalProductKey: string, name: string, sizeText: string, identity: ProductIdentity): Promise<boolean> {
  const stableChannels = [identity.retailerProductId, identity.gtin, identity.upc, identity.sku, identity.canonicalUrl].filter(Boolean).length;
  const expectedConfidence: ProductIdentity["confidence"] = stableChannels >= 2 ? "strong" : stableChannels === 1 ? "moderate" : "weak";
  const primary = identity.primaryType === "retailer_id" ? identity.retailerProductId
    : identity.primaryType === "gtin" ? identity.gtin : identity.primaryType === "upc" ? identity.upc
      : identity.primaryType === "sku" ? identity.sku : identity.primaryType === "canonical_url" ? identity.canonicalUrl : externalProductKey;
  if (!primary || primary !== identity.primaryValue || identity.confidence !== expectedConfidence) return false;
  if (identity.primaryType !== "canonical_url" && identity.primaryValue !== externalProductKey) return false;
  const { fingerprint: _fingerprint, confidence: _confidence, ...input } = identity;
  return identity.fingerprint === await expectedProductIdentityFingerprint(input, name, sizeText);
}

function priceSemanticsPass(store: BrowserCaptureStore, rawText: string, purchasePriceMinor: number, semantics: PriceSemantics | undefined): boolean {
  if (!semantics || semantics.ambiguity !== false || semantics.unitPriceMinor !== purchasePriceMinor) return false;
  const parsed = parseCapturePriceText(rawText);
  if (!parsed || parsed.unitPriceMinor !== semantics.unitPriceMinor
    || parsed.qualifyingQuantity !== semantics.qualifyingQuantity || parsed.totalPriceMinor !== semantics.totalPriceMinor) return false;
  if (semantics.offerType === "multibuy" && (!semantics.condition.includes("quantity") || semantics.qualifyingQuantity <= 1)) return false;
  if (semantics.condition.startsWith("loyalty") && semantics.offerType !== "loyalty") return false;
  if (semantics.condition.startsWith("membership") && semantics.offerType !== "member") return false;
  if (store === "sams" && (!semantics.condition.startsWith("membership") || semantics.offerType !== "member")) return false;
  if (/\b(?:digital\s+coupon|with\s+card|loyalty)\b/i.test(rawText) && !semantics.condition.startsWith("loyalty")) return false;
  return true;
}

function expectedBrowserLocation(store: BrowserCaptureStore, location: string, priceMode: string): boolean {
  const normalizedLocation = location.toLowerCase();
  const normalizedMode = priceMode.toLowerCase();
  const locationPass = store === "walmart" ? /omaha l st|12850 l st|12812 s 38th/.test(normalizedLocation)
    : store === "sams" ? /omaha|13130 l st/.test(normalizedLocation)
    : store === "aldi" ? /ola 42|omaha/.test(normalizedLocation)
    : /17070 audrey|omaha/.test(normalizedLocation);
  const modePass = store === "sams" ? /pickup|club/.test(normalizedMode)
    : store === "walmart" ? /pickup/.test(normalizedMode)
    : /in[-_ ]?store/.test(normalizedMode);
  return locationPass && modePass;
}

function sourceHostPass(store: BrowserCaptureStore, value: string): boolean {
  try {
    const host = new URL(value).hostname.toLowerCase();
    return store === "walmart" ? /(^|\.)walmart\.com$/.test(host)
      : store === "sams" ? /(^|\.)samsclub\.com$/.test(host)
      : store === "aldi" ? /(^|\.)aldi\.us$/.test(host)
      : /(^|\.)fareway\.com$/.test(host);
  } catch { return false; }
}

export function browserCaptureTruthPass(
  store: BrowserCaptureStore,
  identity: { productKey: string; name: string; sizeText: string; purchasePriceMinor: number },
  truth: BrowserCaptureTruth,
): boolean {
  const dualChannel = store === "walmart" || store === "sams";
  const semanticsRequired = Date.parse(truth.capturedAt) >= Date.parse(CAPTURE_SEMANTICS_CUTOVER);
  const expectedRule = dualChannel ? "next-data-price-lines" : "current-price-label";
  if (truth.parser.status !== "exact" || truth.parser.rule !== expectedRule || !sourceHostPass(store, truth.pageUrl)) return false;
  if (!expectedBrowserLocation(store, truth.location, truth.priceMode)) return false;
  if (truth.visible.priceMinor !== identity.purchasePriceMinor || parseCapturePriceText(truth.visible.rawText)?.unitPriceMinor !== identity.purchasePriceMinor) return false;
  if (semanticsRequired && (!truth.pageState || !priceSemanticsPass(store, truth.visible.rawText, identity.purchasePriceMinor, truth.visible.priceSemantics))) return false;
  if (truth.pageState && (normalizeName(truth.pageState.locationText) !== normalizeName(truth.location)
    || !normalizeName(truth.pageState.fulfillmentText).includes(normalizeName(truth.priceMode))
    || !/^en(?:-us)?$/i.test(truth.pageState.locale))) return false;
  if (normalizeName(truth.visible.productName) !== normalizeName(identity.name)) return false;
  if (truth.visible.productKey !== undefined && truth.visible.productKey !== identity.productKey) return false;
  if (truth.visible.sizeText !== undefined && normalizeName(truth.visible.sizeText) !== normalizeName(identity.sizeText)) return false;
  if (dualChannel && !truth.structured) return false;
  if (truth.structured) {
    if (truth.structured.priceMinor !== identity.purchasePriceMinor || parseCapturePriceText(truth.structured.rawText)?.unitPriceMinor !== identity.purchasePriceMinor) return false;
    if (semanticsRequired && (!priceSemanticsPass(store, truth.structured.rawText, identity.purchasePriceMinor, truth.structured.priceSemantics)
      || stableJson(truth.visible.priceSemantics) !== stableJson(truth.structured.priceSemantics))) return false;
    if (normalizeName(truth.structured.productName) !== normalizeName(identity.name)) return false;
    if (truth.structured.productKey !== identity.productKey) return false;
    if (truth.structured.sizeText !== undefined && normalizeName(truth.structured.sizeText) !== normalizeName(identity.sizeText)) return false;
  }
  return true;
}

function accuracyFingerprint(value: { productKey: string; name: string; sizeText: string; purchasePriceMinor: number; truth: BrowserCaptureTruth }): Record<string, unknown> {
  return {
    productKey: value.productKey,
    name: normalizeName(value.name),
    sizeText: normalizeName(value.sizeText),
    purchasePriceMinor: value.purchasePriceMinor,
    location: normalizeName(value.truth.location),
    priceMode: normalizeName(value.truth.priceMode),
    visible: [normalizeName(value.truth.visible.productName), value.truth.visible.priceMinor],
    structured: value.truth.structured ? [value.truth.structured.productKey, normalizeName(value.truth.structured.productName), value.truth.structured.priceMinor] : null,
    priceSemantics: value.truth.visible.priceSemantics ?? null,
    structuredPriceSemantics: value.truth.structured?.priceSemantics ?? null,
    pageState: value.truth.pageState ?? null,
  };
}

function accuracyObservationFingerprint(value: { productKey: string; name: string; sizeText: string; purchasePriceMinor: number; truth: BrowserCaptureTruth }): Record<string, unknown> {
  return {
    productKey: value.productKey,
    name: normalizeName(value.name),
    sizeText: normalizeName(value.sizeText),
    purchasePriceMinor: value.purchasePriceMinor,
    location: normalizeName(value.truth.location),
    priceMode: normalizeName(value.truth.priceMode),
    visible: [normalizeName(value.truth.visible.productName), value.truth.visible.priceMinor],
    structured: value.truth.structured ? [value.truth.structured.productKey, normalizeName(value.truth.structured.productName), value.truth.structured.priceMinor] : null,
    priceSemantics: value.truth.visible.priceSemantics ?? null,
    structuredPriceSemantics: value.truth.structured?.priceSemantics ?? null,
  };
}

function retrievalComplete(term: CaptureAccuracyTerm): boolean {
  const retrieval = term.retrieval;
  if (term.outcome === "empty") return term.rowCount === 0 && retrieval.loadedResultCount === 0 && retrieval.termination === "no-results" && !retrieval.hasMoreResults;
  if (term.outcome !== "success" || term.rowCount !== retrieval.loadedResultCount) return false;
  if (retrieval.termination === "end-of-results") {
    if (retrieval.hasMoreResults) return false;
    return retrieval.availableResultCount === undefined
      || retrieval.loadedResultCount >= Math.min(retrieval.targetResultCount, retrieval.availableResultCount);
  }
  return retrieval.termination === "target-depth" && retrieval.loadedResultCount >= retrieval.targetResultCount;
}

export async function buildBrowserCaptureAccuracy(
  store: BrowserCaptureStore,
  candidates: readonly CaptureAccuracyCandidate[],
  verifications: readonly BrowserCaptureVerification[],
  terms: readonly CaptureAccuracyTerm[],
): Promise<BrowserCaptureAccuracy> {
  const cheapest = new Set<string>();
  const blindSampleEligible = new Set<string>();
  const byTerm = new Map<string, Array<{ index: number; price: number; relevance: number; matchEligible: boolean | undefined }>>();
  candidates.forEach((row, index) => {
    const values = byTerm.get(row.termKey) ?? [];
    values.push({ index, price: row.purchasePriceMinor, relevance: captureCandidateRelevanceScore(row), matchEligible: row.matchEligible });
    byTerm.set(row.termKey, values);
  });
  for (const values of byTerm.values()) {
    const authoredMatchEvidence = values.some((value) => value.matchEligible !== undefined);
    const authoredMatches = values.filter((value) => value.matchEligible === true);
    if (authoredMatchEvidence && authoredMatches.length === 0) continue;
    const bestRelevance = Math.max(...values.map((value) => value.relevance));
    const relevant = authoredMatches.length > 0
      ? authoredMatches
      : (bestRelevance > 0 ? values.filter((value) => value.relevance === bestRelevance) : values);
    for (const value of relevant) blindSampleEligible.add(String(value.index));
    const ranked = relevant.sort((left, right) => left.price - right.price || left.index - right.index);
    cheapest.add(String(ranked[0]?.index));
  }
  const duplicatePrices = new Map<string, Set<number>>();
  for (const row of candidates) {
    const values = duplicatePrices.get(row.productKey) ?? new Set<number>();
    values.add(row.purchasePriceMinor);
    duplicatePrices.set(row.productKey, values);
  }
  const rows: BrowserCaptureAccuracyRow[] = [];
  let allTruthPass = true;
  for (let index = 0; index < candidates.length; index += 1) {
    const candidate = candidates[index]!;
    const discoveryHash = await digestHex(stableJson(accuracyFingerprint(candidate)));
    const rowKey = `row-${(await digestHex(stableJson([candidate.termKey, candidate.productKey, candidate.truth.pageIndex, candidate.truth.resultIndex]))).slice(0, 28)}`;
    const likelyWinner = cheapest.has(String(index));
    const verificationEligible = blindSampleEligible.has(String(index));
    const text = `${candidate.query} ${candidate.name} ${candidate.sizeText}`.toLowerCase();
    const reasons: BrowserCaptureAccuracyRow["riskReasons"] = [];
    if (likelyWinner) reasons.push("likely-board-winner");
    if (likelyWinner && /\b(?:apple|avocado|banana|berry|berries|lemon|lime|orange|peach|pear|pepper|potato|tomato|lettuce|onion|produce)\b/.test(text)) reasons.push("fresh-produce");
    if (likelyWinner && /\b(?:each|ea|ct|count|head|bunch)\b/.test(text)) reasons.push("count-priced");
    if (verificationEligible && /\b\d+\s*(?:\/|for)\s*\$?\d+/i.test(candidate.truth.visible.rawText)) reasons.push("multibuy");
    if (verificationEligible && (candidate.purchasePriceMinor <= 10 || candidate.purchasePriceMinor >= 50_000)) reasons.push("price-outlier");
    if (!candidate.taxonomyPath) reasons.push("missing-taxonomy");
    if (verificationEligible && (duplicatePrices.get(candidate.productKey)?.size ?? 0) > 1) reasons.push("duplicate-price-conflict");
    const verificationRequired = reasons.some((reason) => reason !== "missing-taxonomy");
    if (!browserCaptureTruthPass(store, candidate, candidate.truth)
      || (candidate.truth.pageState?.pageType === "search_results" && normalizeName(candidate.truth.pageState.query ?? "") !== normalizeName(candidate.query))) allTruthPass = false;
    rows.push({ ...candidate, rowKey, discoveryHash, riskReasons: reasons, verificationRequired });
  }
  const blindSamplePool = rows.filter((_row, index) => blindSampleEligible.has(String(index)));
  const deterministicSample = (await Promise.all(blindSamplePool.map(async (row) => ({ row, rank: await digestHex(`browser-capture-sample:${row.rowKey}`) }))))
    .sort((left, right) => left.rank.localeCompare(right.rank) || left.row.rowKey.localeCompare(right.row.rowKey))
    .slice(0, Math.min(100, blindSamplePool.length));
  for (const { row } of deterministicSample) {
    if (!row.riskReasons.includes("deterministic-sample")) row.riskReasons.push("deterministic-sample");
    row.verificationRequired = true;
  }
  const rowMap = new Map(rows.map((row) => [row.rowKey, row]));
  const latest = new Map<string, BrowserCaptureVerification>();
  for (const verification of verifications) {
    const current = latest.get(verification.rowKey);
    if (!current || verification.observedAt > current.observedAt) latest.set(verification.rowKey, verification);
  }
  let matchedVerificationRows = 0;
  for (const row of rows.filter((item) => item.verificationRequired)) {
    const verification = latest.get(row.rowKey);
    if (!verification || verification.discoveryHash !== row.discoveryHash || verification.outcome !== "observed" || !verification.truth
      || verification.productKey === undefined || verification.name === undefined || verification.sizeText === undefined || verification.purchasePriceMinor === undefined) continue;
    if (verification.truth.capturedAt !== verification.observedAt || verification.observedAt <= row.truth.capturedAt || !browserCaptureTruthPass(store, {
      productKey: verification.productKey, name: verification.name, sizeText: verification.sizeText, purchasePriceMinor: verification.purchasePriceMinor,
    }, verification.truth)) continue;
    const verificationHash = await digestHex(stableJson(accuracyObservationFingerprint({
      productKey: verification.productKey, name: verification.name, sizeText: verification.sizeText,
      purchasePriceMinor: verification.purchasePriceMinor, truth: verification.truth,
    })));
    const discoveryObservationHash = await digestHex(stableJson(accuracyObservationFingerprint(row)));
    if (verificationHash === discoveryObservationHash) matchedVerificationRows += 1;
  }
  const requiredVerificationRows = rows.filter((row) => row.verificationRequired).length;
  const retrievalCompleteTerms = terms.filter(retrievalComplete).length;
  const anomalyRows = rows.filter((row) => row.riskReasons.includes("price-outlier") || row.riskReasons.includes("duplicate-price-conflict")).length;
  const relevantVerifications = verifications.filter((verification) => rowMap.has(verification.rowKey));
  const policyVersion = rows.every((row) => Date.parse(row.truth.capturedAt) < Date.parse(CAPTURE_SEMANTICS_CUTOVER)) ? 1 : 2;
  return {
    policyVersion,
    discoveryRows: rows,
    verifications: relevantVerifications,
    requiredVerificationRows,
    matchedVerificationRows,
    unresolvedVerificationRows: requiredVerificationRows - matchedVerificationRows,
    priceAgreementRows: rows.filter((row) => Boolean(row.truth.structured)).length,
    singleChannelRows: rows.filter((row) => !row.truth.structured).length,
    anomalyRows,
    ...(policyVersion === 2 ? {
      pageStateAttestedRows: rows.filter((row) => Boolean(row.truth.pageState)).length,
      promotionSemanticsRows: rows.filter((row) => Boolean(row.truth.visible.priceSemantics)
        && (!row.truth.structured || Boolean(row.truth.structured.priceSemantics))).length,
    } : {}),
    retrievalCompleteTerms,
    pass: allTruthPass && matchedVerificationRows === requiredVerificationRows && retrievalCompleteTerms === terms.length,
  };
}

export async function verifyBrowserCaptureAccuracy(
  store: BrowserCaptureStore,
  accuracy: BrowserCaptureAccuracy,
  terms: readonly CaptureAccuracyTerm[],
): Promise<boolean> {
  const rows = accuracy.discoveryRows;
  const cheapest = new Set<number>();
  const blindSampleEligible = new Set<number>();
  const byTerm = new Map<string, Array<{ index: number; price: number; relevance: number; matchEligible: boolean | undefined }>>();
  rows.forEach((row, index) => {
    const values = byTerm.get(row.termKey) ?? [];
    values.push({ index, price: row.purchasePriceMinor, relevance: captureCandidateRelevanceScore(row), matchEligible: row.matchEligible });
    byTerm.set(row.termKey, values);
  });
  for (const values of byTerm.values()) {
    const authoredMatchEvidence = values.some((value) => value.matchEligible !== undefined);
    const authoredMatches = values.filter((value) => value.matchEligible === true);
    if (authoredMatchEvidence && authoredMatches.length === 0) continue;
    const bestRelevance = Math.max(...values.map((value) => value.relevance));
    const relevant = authoredMatches.length > 0
      ? authoredMatches
      : (bestRelevance > 0 ? values.filter((value) => value.relevance === bestRelevance) : values);
    for (const value of relevant) blindSampleEligible.add(value.index);
    relevant.sort((left, right) => left.price - right.price || left.index - right.index);
    if (relevant[0]) cheapest.add(relevant[0].index);
  }
  const duplicatePrices = new Map<string, Set<number>>();
  for (const row of rows) {
    const values = duplicatePrices.get(row.productKey) ?? new Set<number>();
    values.add(row.purchasePriceMinor);
    duplicatePrices.set(row.productKey, values);
  }
  const sampleRanks: Array<{ index: number; rowKey: string; rank: string }> = [];
  const expectedReasons = new Map<number, BrowserCaptureAccuracyRow["riskReasons"]>();
  let allTruthPass = true;
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    const expectedDiscoveryHash = await digestHex(stableJson(accuracyFingerprint(row)));
    const expectedRowKey = `row-${(await digestHex(stableJson([row.termKey, row.productKey, row.truth.pageIndex, row.truth.resultIndex]))).slice(0, 28)}`;
    if (row.discoveryHash !== expectedDiscoveryHash || row.rowKey !== expectedRowKey) return false;
    const likelyWinner = cheapest.has(index);
    const verificationEligible = blindSampleEligible.has(index);
    const text = `${row.query} ${row.name} ${row.sizeText}`.toLowerCase();
    const reasons: BrowserCaptureAccuracyRow["riskReasons"] = [];
    if (likelyWinner) reasons.push("likely-board-winner");
    if (likelyWinner && /\b(?:apple|avocado|banana|berry|berries|lemon|lime|orange|peach|pear|pepper|potato|tomato|lettuce|onion|produce)\b/.test(text)) reasons.push("fresh-produce");
    if (likelyWinner && /\b(?:each|ea|ct|count|head|bunch)\b/.test(text)) reasons.push("count-priced");
    if (verificationEligible && /\b\d+\s*(?:\/|for)\s*\$?\d+/i.test(row.truth.visible.rawText)) reasons.push("multibuy");
    if (verificationEligible && (row.purchasePriceMinor <= 10 || row.purchasePriceMinor >= 50_000)) reasons.push("price-outlier");
    if (!row.taxonomyPath) reasons.push("missing-taxonomy");
    if (verificationEligible && (duplicatePrices.get(row.productKey)?.size ?? 0) > 1) reasons.push("duplicate-price-conflict");
    expectedReasons.set(index, reasons);
    if (verificationEligible) sampleRanks.push({ index, rowKey: row.rowKey, rank: await digestHex(`browser-capture-sample:${row.rowKey}`) });
    if (!browserCaptureTruthPass(store, row, row.truth)
      || (row.truth.pageState?.pageType === "search_results" && normalizeName(row.truth.pageState.query ?? "") !== normalizeName(row.query))) allTruthPass = false;
  }
  sampleRanks.sort((left, right) => left.rank.localeCompare(right.rank) || left.rowKey.localeCompare(right.rowKey));
  for (const sample of sampleRanks.slice(0, Math.min(100, sampleRanks.length))) expectedReasons.get(sample.index)!.push("deterministic-sample");
  for (let index = 0; index < rows.length; index += 1) {
    const reasons = expectedReasons.get(index)!;
    if (stableJson(rows[index]!.riskReasons) !== stableJson(reasons)
      || rows[index]!.verificationRequired !== reasons.some((reason) => reason !== "missing-taxonomy")) return false;
  }
  const rowMap = new Map(rows.map((row) => [row.rowKey, row]));
  if (accuracy.verifications.some((verification) => !rowMap.has(verification.rowKey))) return false;
  const latest = new Map<string, BrowserCaptureVerification>();
  for (const verification of accuracy.verifications) {
    const current = latest.get(verification.rowKey);
    if (!current || verification.observedAt > current.observedAt) latest.set(verification.rowKey, verification);
  }
  let matchedVerificationRows = 0;
  for (const row of rows) {
    if (!row.verificationRequired) continue;
    const verification = latest.get(row.rowKey);
    if (!verification || verification.discoveryHash !== row.discoveryHash || verification.outcome !== "observed" || !verification.truth
      || verification.productKey === undefined || verification.name === undefined || verification.sizeText === undefined || verification.purchasePriceMinor === undefined) continue;
    if (verification.truth.capturedAt !== verification.observedAt || verification.observedAt <= row.truth.capturedAt || !browserCaptureTruthPass(store, {
      productKey: verification.productKey, name: verification.name, sizeText: verification.sizeText, purchasePriceMinor: verification.purchasePriceMinor,
    }, verification.truth)) continue;
    const verificationHash = await digestHex(stableJson(accuracyObservationFingerprint({
      productKey: verification.productKey, name: verification.name, sizeText: verification.sizeText,
      purchasePriceMinor: verification.purchasePriceMinor, truth: verification.truth,
    })));
    const discoveryObservationHash = await digestHex(stableJson(accuracyObservationFingerprint(row)));
    if (verificationHash === discoveryObservationHash) matchedVerificationRows += 1;
  }
  const requiredVerificationRows = rows.filter((row) => row.verificationRequired).length;
  const retrievalCompleteTerms = terms.filter(retrievalComplete).length;
  const anomalyRows = rows.filter((row) => row.riskReasons.includes("price-outlier") || row.riskReasons.includes("duplicate-price-conflict")).length;
  const policyVersion = rows.every((row) => Date.parse(row.truth.capturedAt) < Date.parse(CAPTURE_SEMANTICS_CUTOVER)) ? 1 : 2;
  const expectedPass = allTruthPass && matchedVerificationRows === requiredVerificationRows && retrievalCompleteTerms === terms.length;
  return accuracy.policyVersion === policyVersion
    && accuracy.requiredVerificationRows === requiredVerificationRows
    && accuracy.matchedVerificationRows === matchedVerificationRows
    && accuracy.unresolvedVerificationRows === requiredVerificationRows - matchedVerificationRows
    && accuracy.priceAgreementRows === rows.filter((row) => Boolean(row.truth.structured)).length
    && accuracy.singleChannelRows === rows.filter((row) => !row.truth.structured).length
    && accuracy.anomalyRows === anomalyRows
    && (policyVersion !== 2 || accuracy.pageStateAttestedRows === rows.filter((row) => Boolean(row.truth.pageState)).length)
    && (policyVersion !== 2 || accuracy.promotionSemanticsRows === rows.filter((row) => Boolean(row.truth.visible.priceSemantics)
      && (!row.truth.structured || Boolean(row.truth.structured.priceSemantics))).length)
    && accuracy.retrievalCompleteTerms === retrievalCompleteTerms
    && accuracy.pass === expectedPass;
}

export function centsFromLegacyDollars(value: number): number {
  if (!Number.isFinite(value) || value < 0) throw new Error("legacy dollar amount must be non-negative and finite");
  return Math.round(value * 100);
}

export function microsFromLegacyPerUnit(value: number): number {
  if (!Number.isFinite(value) || value < 0) throw new Error("legacy per-unit amount must be non-negative and finite");
  return Math.round(value * 1_000_000);
}
