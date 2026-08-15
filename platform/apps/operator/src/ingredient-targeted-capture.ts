import { createHash } from "node:crypto";
import { ingredientStoreCaptureResultSchema, ingredientStoreQaCompleteSchema } from "@thriftycrew/contracts";
import { digestHex, isClearlyIngredientDerivative, isClearlyNonFoodIngredientProduct, matchesIngredientCommodityExclusion, normalizeName, stableJson } from "@thriftycrew/domain";
import type { z } from "zod";

type CapturePayload = z.infer<typeof ingredientStoreCaptureResultSchema>;
type QaPayload = z.infer<typeof ingredientStoreQaCompleteSchema>;

interface ClaimedCheck {
  id: string;
  store_location_id: CapturePayload["result"]["storeLocationId"];
  lease_owner: string;
  lease_generation: number;
  query_plan_hash: string;
  canonical_term: string;
  aliases_json: string;
  exclusions_json: string;
  commodity_proposal_json: string;
  capture_result_json?: string | null;
}

interface AdapterChunk {
  version: 2;
  phase: "discovery" | "verification";
  store: string;
  canary: { evidenceUrl: string; observedAt: string; location?: string; exactAddress?: string; priceMode?: string;
    locationId?: string; retailerLocationKey?: string; locationVerified: boolean; priceModeVerified: boolean };
  terms?: Array<Record<string, unknown>>;
  rows?: Array<Record<string, unknown>>;
  verifications?: Array<Record<string, unknown>>;
}

const STORE = {
  "aldi-omaha-446-048": { adapter: "aldi", seller: "Aldi", mode: "in_store", host: "www.aldi.us", membership: false },
  "bakers-saddle-creek": { adapter: "bakers", seller: "Baker's", mode: "in_store", host: "www.bakersplus.com", membership: false },
  "family-fare-omaha-6401": { adapter: "family-fare", seller: "Family Fare", mode: "pickup", host: "www.shopfamilyfare.com", membership: false },
  "fareway-omaha-043": { adapter: "fareway", seller: "Fareway", mode: "in_store", host: "shop.fareway.com", membership: false },
  "hy-vee-omaha-1465": { adapter: "hy-vee", seller: "Hy-Vee", mode: "in_store", host: "www.hy-vee.com", membership: false },
  "sams-omaha": { adapter: "sams", seller: "Sam's Club", mode: "club", host: "www.samsclub.com", membership: true },
  "walmart-omaha": { adapter: "walmart", seller: "Walmart", mode: "pickup", host: "www.walmart.com", membership: false },
} as const;

const MASS_GRAMS: Record<string, number> = { oz: 28.349523125, lb: 453.59237, gram: 1, kg: 1000 };
const VOLUME_ML: Record<string, number> = { fl_oz: 29.5735295625, ml: 1, liter: 1000, gal: 3785.411784, qt: 946.352946, pt: 473.176473 };
export function isClearlyNonFoodProduct(name: string, taxonomy = ""): boolean {
  return isClearlyNonFoodIngredientProduct(name, taxonomy);
}

export function isClearlyDerivativeProduct(commodityId: string, name: string): boolean {
  return isClearlyIngredientDerivative(commodityId, name);
}

function sha(value: unknown): string {
  return createHash("sha256").update(stableJson(value)).digest("hex");
}

function parsedPackage(sizeText: string): { unit: string; quantity: number } | null {
  const normalized = sizeText.toLowerCase().replace(/fluid ounces?/g, "fl oz").replace(/ounces?/g, "oz")
    .replace(/pounds?/g, "lb").replace(/grams?/g, "g").replace(/kilograms?/g, "kg")
    .replace(/liters?/g, "l").replace(/gallons?/g, "gal").replace(/counts?/g, "ct").trim();
  const pack = normalized.match(/^(\d+)\s*[x×]\s*([0-9]+(?:\.[0-9]+)?)\s*(sq\s*ft|square\s+feet|fl\s*oz|oz|lb|ml|l|g|kg|ct|ea|each|dozen|gal|qt|pt)\b/);
  const match = pack ?? normalized.match(/([0-9]+(?:\.[0-9]+)?)\s*(sq\s*ft|square\s+feet|fl\s*oz|oz|lb|ml|l|g|kg|ct|ea|each|dozen|gal|qt|pt)\b/);
  if (!match) {
    if (/^(?:each|ea)$/.test(normalized)) return { unit: "each", quantity: 1 };
    if (normalized === "dozen") return { unit: "dozen", quantity: 1 };
    return null;
  }
  const count = pack ? Number(match[1]) : 1;
  const quantity = Number(match[pack ? 2 : 1]) * count;
  const raw = String(match[pack ? 3 : 2]).replace(/\s/g, "");
  const unit = ["sqft", "squarefeet"].includes(raw) ? "sq_ft" : raw === "floz" ? "fl_oz" : raw === "l" ? "liter" : raw === "g" ? "gram"
    : ["ct", "ea", "each"].includes(raw) ? "each" : raw;
  return Number.isFinite(quantity) && quantity > 0 ? { unit, quantity } : null;
}

function convertQuantity(quantity: number, from: string, to: string): number | null {
  if (from === to) return quantity;
  if (from in MASS_GRAMS && to in MASS_GRAMS) return quantity * MASS_GRAMS[from]! / MASS_GRAMS[to]!;
  if (from in VOLUME_ML && to in VOLUME_ML) return quantity * VOLUME_ML[from]! / VOLUME_ML[to]!;
  if (from === "each" && to === "dozen") return quantity / 12;
  if (from === "dozen" && to === "each") return quantity * 12;
  return null;
}

function regexes(patterns: string[]): RegExp[] {
  return patterns.map((pattern) => new RegExp(pattern.replace(/^\(\?i\)/, ""), "i"));
}

export function matchesCommodityExclusion(patterns: string[], productName: string, packageText = ""): boolean {
  return matchesIngredientCommodityExclusion(patterns, productName, packageText);
}

function rowIdentity(row: Record<string, unknown>) {
  const truth = row._capture as Record<string, any> | undefined;
  const offer = truth?.offer as Record<string, any> | undefined;
  const productId = String(row.id ?? offer?.retailerProductId ?? row.url ?? row.href ?? "").trim();
  const productName = String(offer?.productName ?? row.n ?? row.name ?? "").trim();
  const sourceUrl = String(offer?.sourceUrl ?? row.url ?? row.href ?? "").trim();
  const packageText = String(offer?.sizeText ?? row.size ?? "").trim();
  const packagePriceMinor = Number(offer?.purchasePriceMinor ?? truth?.visible?.priceMinor);
  return { truth, offer, productId, productName, sourceUrl, packageText, packagePriceMinor };
}

function canonicalCandidate(row: Record<string, unknown>, check: ClaimedCheck, evidenceHash: string): CapturePayload["candidates"][number] {
  const store = STORE[check.store_location_id];
  const proposal = JSON.parse(check.commodity_proposal_json) as { id: string; unit: string; include: string[]; exclude: string[] };
  const identity = rowIdentity(row);
  const rejections: string[] = [];
  let url: URL | null = null;
  try { url = new URL(identity.sourceUrl); } catch { rejections.push("invalid_source_url"); }
  if (url?.hostname !== store.host) rejections.push("wrong_first_party_host");
  if (!identity.productId || !identity.productName) rejections.push("missing_product_identity");
  if (isClearlyNonFoodProduct(identity.productName, String(row.taxonomy_path ?? row.taxonomy ?? ""))) rejections.push("non_food_product");
  if (isClearlyDerivativeProduct(proposal.id, identity.productName)) rejections.push("ingredient_derivative_product");
  if (!regexes(proposal.include).some((rule) => rule.test(identity.productName))) rejections.push("identity_not_included");
  if (matchesCommodityExclusion(proposal.exclude, identity.productName, identity.packageText)) rejections.push("identity_excluded");
  const availability = identity.offer?.availability ?? {};
  if (availability.eligible !== true || availability.status !== "in_stock") rejections.push("not_source_verified_in_stock");
  const parsed = parsedPackage(identity.packageText);
  const converted = parsed ? convertQuantity(parsed.quantity, parsed.unit, proposal.unit) : null;
  if (!parsed) rejections.push("unparseable_package_size");
  else if (converted === null) rejections.push("incompatible_basis_unit");
  if (!Number.isSafeInteger(identity.packagePriceMinor) || identity.packagePriceMinor <= 0) rejections.push("invalid_package_price");
  const semantics = identity.offer?.priceSemantics ?? identity.truth?.visible?.priceSemantics ?? {};
  const rawKind = String(semantics.offerType ?? "everyday");
  const offerKind = rawKind === "member" ? "member" : rawKind === "markdown" ? "markdown" : ["sale", "multibuy", "loyalty"].includes(rawKind) ? "sale" : "everyday";
  const validFrom = typeof semantics.validFrom === "string" ? semantics.validFrom : null;
  const validTo = typeof semantics.validTo === "string" ? semantics.validTo : null;
  if (["sale", "markdown"].includes(offerKind) && (!validFrom || !validTo || validTo <= validFrom)) rejections.push("missing_promotion_window");
  const normalizedBasisQtyMicros = Math.max(1, Math.round((converted ?? 1) * 1_000_000));
  const perUnitMicros = Math.round((Math.max(1, identity.packagePriceMinor || 1) * 10_000 * 1_000_000) / normalizedBasisQtyMicros);
  return {
    productId: identity.productId || sha(identity).slice(0, 24), sourceUrl: identity.sourceUrl || `https://${store.host}/`,
    productName: identity.productName || "Rejected retailer result", sellerName: String(identity.offer?.sellerName || store.seller),
    fulfillmentMode: store.mode, availabilityText: String(availability.rawText || availability.status || "Availability not proven"),
    packageText: identity.packageText || "Unknown package", packagePriceMinor: Math.max(1, identity.packagePriceMinor || 1),
    normalizedBasisUnit: proposal.unit as CapturePayload["candidates"][number]["normalizedBasisUnit"], normalizedBasisQtyMicros,
    perUnitMicros, offerKind, validFrom, validTo, loyaltyRequired: /loyalty/.test(String(semantics.condition ?? "")),
    membershipRequired: store.membership || /membership/.test(String(semantics.condition ?? "")), eligible: rejections.length === 0,
    rejectionCodes: [...new Set(rejections)].sort(), evidenceHash,
  };
}

export async function buildIngredientCapturePayload(check: ClaimedCheck, chunks: AdapterChunk[], evidence: CapturePayload["evidence"], now = new Date()): Promise<CapturePayload> {
  const store = STORE[check.store_location_id];
  if (!check.commodity_proposal_json) throw new Error(`${check.id} has no locked commodity definition`);
  const proposal = JSON.parse(check.commodity_proposal_json) as { searchTerms: string[] };
  const expectedTerms = [...new Set(proposal.searchTerms.map(normalizeName))];
  const relevant = chunks.filter((chunk) => chunk.version === 2 && chunk.phase === "discovery" && chunk.store === store.adapter);
  if (relevant.length === 0) throw new Error(`${check.id} has no ${store.adapter} discovery evidence`);
  if (relevant.some((chunk) => !chunk.canary.locationVerified || !chunk.canary.priceModeVerified)) throw new Error(`${check.id} has an invalid location/mode canary`);
  const termRecords = relevant.flatMap((chunk) => chunk.terms ?? []);
  const byQuery = new Map(termRecords.map((term) => [normalizeName(String(term.query ?? "")), term]));
  for (const term of expectedTerms) {
    const record = byQuery.get(term);
    const retrieval = record?.retrieval as Record<string, unknown> | undefined;
    const outcome = String(record?.outcome ?? "");
    const complete = (outcome === "success" && retrieval?.termination === "end-of-results")
      || (outcome === "empty" && ["no-results", "end-of-results"].includes(String(retrieval?.termination)));
    if (!record || !complete || retrieval?.hasMoreResults !== false) {
      const reason = record?.reason ? `: ${String(record.reason).slice(0, 2000)}` : "";
      throw new Error(`${check.id} lacks end-of-results coverage for ${term}${reason}`);
    }
  }
  const rows = relevant.flatMap((chunk) => chunk.rows ?? []).filter((row) => expectedTerms.includes(normalizeName(String(row.q ?? row.term ?? ""))));
  const grouped = new Map<string, Record<string, unknown>[]>();
  for (const row of rows) {
    const id = rowIdentity(row).productId;
    if (!id) continue;
    grouped.set(id, [...(grouped.get(id) ?? []), row]);
  }
  const candidates: CapturePayload["candidates"] = [];
  for (const [productId, copies] of grouped) {
    const semantics = copies.map((row) => {
      const i = rowIdentity(row);
      const availability = i.offer?.availability ?? {};
      const priceSemantics = i.offer?.priceSemantics ?? i.truth?.visible?.priceSemantics ?? {};
      return stableJson({ productId, name: i.productName, url: i.sourceUrl, size: i.packageText, price: i.packagePriceMinor,
        sellerName: i.offer?.sellerName ?? null, availability, priceSemantics });
    });
    if (new Set(semantics).size !== 1) throw new Error(`${check.id} captured conflicting facts for product ${productId}`);
    candidates.push(canonicalCandidate(copies[0]!, check, await digestHex(stableJson(copies.map((row) => row._capture)))));
  }
  candidates.sort((a, b) => a.productId.localeCompare(b.productId));
  const candidateSetHash = await digestHex(stableJson(candidates.map(({ evidenceHash: _evidenceHash, ...candidate }) => candidate)));
  const eligible = candidates.filter((candidate) => candidate.eligible).sort((a, b) => a.perUnitMicros - b.perUnitMicros || a.productId.localeCompare(b.productId));
  const winner = eligible[0];
  const checkedAt = relevant.map((chunk) => chunk.canary.observedAt).sort().at(-1) ?? now.toISOString();
  const common = { storeLocationId: check.store_location_id, checkedAt, queryTerms: proposal.searchTerms, searchComplete: true,
    qualifyingProductsExamined: eligible.length, locationVerified: true, priceModeVerified: true } as const;
  const result: CapturePayload["result"] = winner ? {
    ...common, outcome: "priced", sourceUrl: winner.sourceUrl, evidenceSummary: `Complete first-party ${store.seller} Omaha search examined ${candidates.length} unique products and selected the cheapest of ${eligible.length} eligible exact matches.`,
    productName: winner.productName, sellerName: winner.sellerName, fulfillmentMode: winner.fulfillmentMode,
    availabilityText: winner.availabilityText, packageText: winner.packageText, packagePriceMinor: winner.packagePriceMinor,
    normalizedBasisUnit: winner.normalizedBasisUnit, normalizedBasisQtyMicros: winner.normalizedBasisQtyMicros,
    perUnitMicros: winner.perUnitMicros, offerKind: winner.offerKind, validFrom: winner.validFrom, validTo: winner.validTo,
    loyaltyRequired: winner.loyaltyRequired, membershipRequired: winner.membershipRequired,
  } : {
    ...common, outcome: "not_found", sourceUrl: evidence.sourceUrl,
    evidenceSummary: `Complete first-party ${store.seller} Omaha search reached end of results for every locked query and found no eligible exact match.`,
    productName: null, sellerName: null, fulfillmentMode: null, availabilityText: null, packageText: null,
    packagePriceMinor: null, normalizedBasisUnit: null, normalizedBasisQtyMicros: null, perUnitMicros: null,
    offerKind: null, validFrom: null, validTo: null, loyaltyRequired: false, membershipRequired: false,
  };
  const expiresAt = new Date(now.getTime() + 60 * 60 * 1000).toISOString();
  const coverage = expectedTerms.map((term) => {
    const record = byQuery.get(term)!;
    const retrieval = record.retrieval as Record<string, unknown>;
    const completedAt = String(record.finishedAt ?? checkedAt);
    return { normalizedQuery: term, pageCount: Number(retrieval.pageCount), resultCount: Number(record.rowCount),
      retailerResultTotal: typeof retrieval.availableResultCount === "number" ? retrieval.availableResultCount : Number(record.rowCount),
      terminationReason: "end_of_results" as const, paginationHash: sha({ term, retrieval }), evidenceHash: evidence.sha256,
      completedAt, expiresAt };
  });
  return ingredientStoreCaptureResultSchema.parse({ owner: check.lease_owner, leaseGeneration: Number(check.lease_generation),
    producerVersion: "targeted-adapter-bridge-v1", queryPlanHash: check.query_plan_hash, result, candidates, evidence,
    candidateSetHash, coverage });
}

export function buildIngredientQaPayload(check: ClaimedCheck, verification: AdapterChunk, evidence: QaPayload["verifierEvidence"]): QaPayload {
  const captured = JSON.parse(String(check.capture_result_json ?? "null")) as CapturePayload["result"] | null;
  if (!captured) throw new Error(`${check.id} has no frozen capture result`);
  if (captured.outcome === "priced") {
    if (verification.phase !== "verification") throw new Error("priced QA requires an independent verification chunk");
    const match = (verification.verifications ?? []).some((item) => item.outcome === "observed"
      && item.productKey === captured.sourceUrl && item.name === captured.productName && item.sizeText === captured.packageText
      && Number(item.purchasePriceMinor) === captured.packagePriceMinor);
    if (!match) throw new Error(`${check.id} independent verification does not reproduce the frozen winner`);
  } else if (captured.outcome === "not_found") {
    if (verification.phase !== "discovery") throw new Error("not-found QA requires an independent repeated discovery chunk");
    const complete = new Set((verification.terms ?? []).filter((item) => {
      const outcome = String(item.outcome);
      const retrieval = item.retrieval as Record<string, unknown> | undefined;
      const terminal = (outcome === "success" && retrieval?.termination === "end-of-results")
        || (outcome === "empty" && ["no-results", "end-of-results"].includes(String(retrieval?.termination)));
      return terminal && retrieval?.hasMoreResults === false;
    })
      .map((item) => normalizeName(String(item.query ?? ""))));
    if (!captured.queryTerms.every((term) => complete.has(normalizeName(term)))) throw new Error(`${check.id} independent pass did not reproduce complete no-match coverage`);
    const expected = new Set(captured.queryTerms.map(normalizeName));
    const rows = (verification.rows ?? []).filter((row) => expected.has(normalizeName(String(row.q ?? row.term ?? ""))));
    if (rows.some((row) => canonicalCandidate(row, check, "0".repeat(64)).eligible)) {
      throw new Error(`${check.id} independent pass found an eligible exact candidate`);
    }
  }
  return ingredientStoreQaCompleteSchema.parse({ owner: check.lease_owner, leaseGeneration: Number(check.lease_generation),
    verdict: captured.outcome, verifierVersion: "targeted-independent-verifier-v1", verifierEvidence: evidence,
    validatorVersions: { schema: "ingredient-store-qa-v3", winner: "exact-product-price-size-v1" }, findings: [] });
}

export function mergeIngredientQaDiscoveryChunks(chunks: AdapterChunk[]): AdapterChunk {
  const discovery = chunks.filter((chunk) => chunk.version === 2 && chunk.phase === "discovery");
  if (discovery.length === 0) throw new Error("no independent discovery chunks supplied");
  const store = discovery[0]!.store;
  if (discovery.some((chunk) => chunk.store !== store)) throw new Error("independent discovery chunks span multiple stores");
  const newest = [...discovery].sort((a, b) => a.canary.observedAt.localeCompare(b.canary.observedAt)).at(-1)!;
  return { version: 2, phase: "discovery", store, canary: newest.canary,
    terms: discovery.flatMap((chunk) => chunk.terms ?? []), rows: discovery.flatMap((chunk) => chunk.rows ?? []) };
}

export type { AdapterChunk, ClaimedCheck };
