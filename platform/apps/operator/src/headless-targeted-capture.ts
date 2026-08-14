import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import type { AdapterChunk, ClaimedCheck } from "./ingredient-targeted-capture";

type HeadlessStore = "bakers" | "family-fare" | "hy-vee";
type JsonRecord = Record<string, any>;
type FetchLike = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;
type CaptureRecord = { query: string; rows: JsonRecord[]; total: number; examined: number; pages: number;
  excludedResults: JsonRecord[]; partitionProof?: JsonRecord[]; failure?: string };
type HeadlessCaptureOptions = { krogerCredentialsFile?: string; familyFareCatalogFile?: string; fetchImpl?: FetchLike;
  termConcurrency?: number; pageConcurrency?: number };

const STORE = {
  bakers: { location: "Baker's Saddle Creek", locationId: "61500319", priceMode: "in_store", seller: "Baker's",
    evidenceUrl: "https://www.bakersplus.com/stores/grocery/ne/omaha/bakers-saddle-creek/615/00319" },
  "family-fare": { location: "Family Fare 50th & Grover", locationId: "6401", priceMode: "pickup", seller: "Family Fare",
    evidenceUrl: "https://www.shopfamilyfare.com/store/family-fare/products" },
  "hy-vee": { location: "Omaha Hy-Vee #01", locationId: "1465", priceMode: "in_store", seller: "Hy-Vee",
    evidenceUrl: "https://www.hy-vee.com/aisles-online/search" },
} as const;

const USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/148 Safari/537.36";
const DEFAULT_TERM_CONCURRENCY: Record<HeadlessStore, number> = { bakers: 8, "family-fare": 12, "hy-vee": 8 };
const DEFAULT_PAGE_CONCURRENCY = 8;
const KROGER_PAGE_SIZE = 50;
const KROGER_MAX_START = 250;
const KROGER_BRANDS_PER_PARTITION = 20;

export class HeadlessSourceLimitError extends Error {
  readonly code = "HEADLESS_SOURCE_LIMIT";
  constructor(message: string) {
    super(`[headless_source_limit] ${message}`);
    this.name = "HeadlessSourceLimitError";
  }
}

export async function mapWithConcurrency<T, R>(values: readonly T[], concurrency: number,
  operation: (value: T, index: number) => Promise<R>): Promise<R[]> {
  if (!Number.isSafeInteger(concurrency) || concurrency < 1) throw new Error("concurrency must be a positive integer");
  const results = new Array<R>(values.length);
  let cursor = 0;
  await Promise.all(Array.from({ length: Math.min(concurrency, values.length) }, async () => {
    while (cursor < values.length) {
      const index = cursor;
      cursor += 1;
      results[index] = await operation(values[index]!, index);
    }
  }));
  return results;
}

function concurrencyLimitedFetch(fetchImpl: FetchLike, concurrency: number): FetchLike {
  let active = 0;
  const waiting: Array<() => void> = [];
  return async (input, init) => {
    if (active >= concurrency) await new Promise<void>((resolve) => waiting.push(resolve));
    active += 1;
    try {
      return await fetchImpl(input, init);
    } finally {
      active -= 1;
      waiting.shift()?.();
    }
  };
}

export function offsetPageStarts(total: number, pageSize: number): number[] {
  if (!Number.isSafeInteger(total) || total < 0 || !Number.isSafeInteger(pageSize) || pageSize < 1) {
    throw new Error("pagination requires a non-negative integer total and positive integer page size");
  }
  return Array.from({ length: Math.ceil(total / pageSize) }, (_, index) => index * pageSize);
}

export function assertCompleteResultEnvelope(store: string, total: number, pages: Array<{ offset: number; count: number; ids: string[] }>, pageSize: number): void {
  const expectedOffsets = offsetPageStarts(total, pageSize);
  if (pages.length !== Math.max(1, expectedOffsets.length)) throw new Error(`${store} pagination returned ${pages.length} pages for ${total} results`);
  const ordered = [...pages].sort((left, right) => left.offset - right.offset);
  const actualOffsets = ordered.map((page) => page.offset);
  const normalizedExpected = expectedOffsets.length ? expectedOffsets : [0];
  if (actualOffsets.some((offset, index) => offset !== normalizedExpected[index])) throw new Error(`${store} pagination did not cover every expected offset`);
  const examined = ordered.reduce((sum, page) => sum + page.count, 0);
  if (examined !== total) throw new Error(`${store} pagination examined ${examined} of ${total} reported results`);
  if (ordered.some((page) => page.ids.length !== page.count || page.ids.some((id) => !id))) {
    throw new Error(`${store} pagination returned a result without a stable product identity`);
  }
  const ids = ordered.flatMap((page) => page.ids);
  if (new Set(ids).size !== ids.length) throw new Error(`${store} pagination returned overlapping product identities`);
}

export function headlessPriceMinor(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) return Math.round(value * 100);
  const text = String(value ?? "").trim();
  if (!/^\$?\d+(?:\.\d{1,2})?$/.test(text)) return null;
  const parsed = Number(text.replace("$", ""));
  return Number.isFinite(parsed) && parsed > 0 ? Math.round(parsed * 100) : null;
}

function slug(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 90);
}

export function stableProductName(value: unknown): string {
  return String(value ?? "").replace(/Ã‚Â®|Ã‚Â™|Â®|Â™|[®™©]/g, "").replace(/\s+/g, " ").trim();
}

function searchTokens(value: string): string[] {
  return value.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().split(/\s+/).filter(Boolean);
}

export function familyFareCatalogMatches(query: string, productName: string): boolean {
  const productTokens = new Set(searchTokens(productName));
  return searchTokens(query).every((token) => productTokens.has(token));
}

async function jsonFetch(url: string, init: RequestInit = {}, attempts = 2, fetchImpl: FetchLike = fetch): Promise<JsonRecord> {
  let last: unknown;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await fetchImpl(url, { ...init, signal: AbortSignal.timeout(30_000) });
      const text = await response.text();
      const bodyReportsThrottle = /"error_code"\s*:\s*429\b/.test(text);
      if (response.status === 429 || bodyReportsThrottle) {
        throw new Error(`source throttled HTTP ${response.status}: ${new URL(url).hostname}`);
      }
      if (!response.ok) throw new Error(`source returned HTTP ${response.status}: ${new URL(url).hostname}`);
      return JSON.parse(text) as JsonRecord;
    } catch (error) {
      last = error;
      if (/HTTP 429|HTTP 4\d\d/.test(String(error)) || attempt === attempts) break;
      await new Promise((resolve) => setTimeout(resolve, attempt * 500));
    }
  }
  throw last instanceof Error ? last : new Error(String(last));
}

async function krogerToken(credentialsFile: string, fetchImpl: FetchLike): Promise<string> {
  const credentials = JSON.parse(await readFile(credentialsFile, "utf8")) as { client_id?: string; client_secret?: string };
  if (!credentials.client_id || !credentials.client_secret) throw new Error("Kroger product API credentials are missing");
  const authorization = Buffer.from(`${credentials.client_id}:${credentials.client_secret}`).toString("base64");
  const response = await jsonFetch("https://api.kroger.com/v1/connect/oauth2/token", {
    method: "POST", headers: { authorization: `Basic ${authorization}`, "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&scope=product.compact",
  }, 1, fetchImpl);
  if (!response.access_token) throw new Error("Kroger token response omitted access_token");
  return String(response.access_token);
}

export function headlessPriceSemantics(current: number, regular: number | null, effective?: string | null, expires?: string | null) {
  const discounted = regular !== null && regular > current;
  if (discounted && (!effective || !expires || Date.parse(expires) <= Date.parse(effective))) return null;
  return { offerType: discounted ? "sale" : "everyday", condition: "none", unitPriceMinor: current,
    qualifyingQuantity: 1, totalPriceMinor: current, ...(discounted ? { regularPriceMinor: regular, validFrom: effective, validTo: expires } : {}), ambiguity: false };
}

function capturedRow(store: HeadlessStore, query: string, item: { id: string; name: string; size: string; url: string;
  price: number; regular: number | null; available: boolean; rawAvailability: string; effective?: string | null; expires?: string | null },
  pageIndex: number, resultIndex: number, observedAt: string): JsonRecord | null {
  if (!item.id || !item.name || !item.size || !item.url || !Number.isSafeInteger(item.price) || item.price <= 0) return null;
  const semantics = headlessPriceSemantics(item.price, item.regular, item.effective, item.expires);
  if (!semantics) return null;
  const config = STORE[store];
  const offer = { version: 1, retailerProductId: item.id, productName: item.name, sizeText: item.size,
    rawPriceText: `$${(item.price / 100).toFixed(2)}`, purchasePriceMinor: item.price, sellerName: config.seller,
    availability: { status: item.available ? "in_stock" : "unavailable", rawText: item.rawAvailability,
      fulfillmentMode: config.priceMode, locationId: config.locationId, eligible: item.available },
    priceSemantics: semantics, observedAt, sourceUrl: item.url };
  return { term: query, id: item.id, name: item.name, n: item.name, size: item.size, url: item.url,
    taxonomy_path: "Grocery", _capture: { capturedAt: observedAt, pageUrl: item.url, location: config.location,
      priceMode: config.priceMode, pageIndex, resultIndex,
      pageState: { pageType: "api_search_results", query, resultRegionPresent: true, challengeDetected: false,
        currency: "USD", locale: "en-US", locationText: config.location, fulfillmentText: config.priceMode },
      visible: { rawText: `$${(item.price / 100).toFixed(2)}`, priceMinor: item.price, productName: item.name,
        productKey: item.id, sizeText: item.size, priceSemantics: semantics },
      structured: { rawText: `$${(item.price / 100).toFixed(2)}`, priceMinor: item.price, productName: item.name,
        productKey: item.id, sizeText: item.size, priceSemantics: semantics }, offer,
      parser: { status: "exact", rule: `${store}-first-party-api-v2`, notes: "Store-bound first-party API response." } } };
}

async function captureBakers(query: string, token: string, observedAt: string, fetchImpl: FetchLike, pageConcurrency: number) {
  const rows: JsonRecord[] = []; const excludedResults: JsonRecord[] = [];
  type ProductHit = { product: JsonRecord; pageIndex: number; resultIndex: number };
  type Partition = { label: string; filters: { brands?: string[]; fulfillment?: string }; total: number; pages: number;
    products: ProductHit[]; proof: JsonRecord };
  let requestPages = 0;
  const fetchPage = async (start: number, filters: Partition["filters"] = {}, term = query) => {
    const url = new URL("https://api.kroger.com/v1/products");
    url.searchParams.set("filter.locationId", STORE.bakers.locationId); url.searchParams.set("filter.term", term);
    url.searchParams.set("filter.limit", String(KROGER_PAGE_SIZE)); url.searchParams.set("filter.start", String(start));
    if (filters.brands?.length) url.searchParams.set("filter.brand", filters.brands.join("|"));
    if (filters.fulfillment) url.searchParams.set("filter.fulfillment", filters.fulfillment);
    const response = await jsonFetch(url.href, { headers: { authorization: `Bearer ${token}`, accept: "application/json" } }, 3, fetchImpl);
    requestPages += 1;
    const products = Array.isArray(response.data) ? response.data : [];
    const total = Number(response.meta?.pagination?.total);
    if (!Number.isSafeInteger(total) || total < 0) throw new Error("Baker's omitted a valid pagination total");
    const reportedStart = response.meta?.pagination?.start;
    if (reportedStart !== undefined && Number(reportedStart) !== start) throw new Error(`Baker's returned offset ${reportedStart} for requested offset ${start}`);
    return { start, total, products };
  };

  const captureBounded = async (label: string, filters: Partition["filters"], knownFirst?: Awaited<ReturnType<typeof fetchPage>>): Promise<Partition> => {
    const first = knownFirst ?? await fetchPage(0, filters);
    if (first.total > KROGER_MAX_START + KROGER_PAGE_SIZE) {
      if ((filters.brands?.length ?? 0) > 1) {
        const midpoint = Math.ceil(filters.brands!.length / 2);
        const children = await Promise.all([
          captureBounded(`${label}:a`, { ...filters, brands: filters.brands!.slice(0, midpoint) }),
          captureBounded(`${label}:b`, { ...filters, brands: filters.brands!.slice(midpoint) }),
        ]);
        const products = unionProductHits(children.flatMap((child) => child.products), `${label} brand split`);
        if (products.length !== first.total) throw new HeadlessSourceLimitError(
          `Baker's ${label} split recovered ${products.length} of ${first.total} reported products for ${JSON.stringify(query)}`);
        const pages = 1 + children.reduce((sum, child) => sum + child.pages, 0);
        return { label, filters, total: first.total, pages, products,
          proof: { label, filters, reportedTotal: first.total, recoveredUnique: products.length, requestPages: pages,
            strategy: "recursive_brand_split", children: children.map((child) => child.proof) } };
      }
      if (filters.brands?.length === 1 && !filters.fulfillment) {
        const fulfillment = await Promise.all(["ais", "csp", "dth", "sth"].map((mode) =>
          captureBounded(`${label}:${mode}`, { ...filters, fulfillment: mode })));
        const products = unionProductHits(fulfillment.flatMap((child) => child.products), `${label} fulfillment split`);
        if (products.length !== first.total) throw new HeadlessSourceLimitError(
          `Baker's ${label} fulfillment split recovered ${products.length} of ${first.total} reported products for ${JSON.stringify(query)}`);
        const pages = 1 + fulfillment.reduce((sum, child) => sum + child.pages, 0);
        return { label, filters, total: first.total, pages, products,
          proof: { label, filters, reportedTotal: first.total, recoveredUnique: products.length, requestPages: pages,
            strategy: "fulfillment_union", children: fulfillment.map((child) => child.proof) } };
      }
      throw new HeadlessSourceLimitError(`Baker's ${label} reports ${first.total} products beyond the authoritative offset ceiling`);
    }
    const starts = offsetPageStarts(first.total, KROGER_PAGE_SIZE);
    const remaining = await mapWithConcurrency(starts.slice(1), pageConcurrency, (start) => fetchPage(start, filters));
    const pageResults = [first, ...remaining];
    if (pageResults.some((page) => page.total !== first.total)) throw new Error(`Baker's ${label} pagination total changed during capture`);
    assertCompleteResultEnvelope(`Baker's ${label}`, first.total, pageResults.map((page) => ({ offset: page.start,
      count: page.products.length, ids: page.products.map((product: JsonRecord) => String(product.productId ?? "")) })), KROGER_PAGE_SIZE);
    const products = pageResults.flatMap((page, pageIndex) => page.products.map((product: JsonRecord, resultIndex: number) => ({ product, pageIndex, resultIndex })));
    if (filters.brands?.length) {
      const expectedBrands = new Set(filters.brands);
      const unexpected = products.find((hit) => !expectedBrands.has(String(hit.product.brand ?? "")));
      if (unexpected) throw new HeadlessSourceLimitError(`Baker's ${label} returned brand ${JSON.stringify(unexpected.product.brand)} outside its deterministic partition`);
    }
    return { label, filters, total: first.total, pages: pageResults.length, products,
      proof: { label, filters, reportedTotal: first.total, recoveredUnique: products.length,
        requestPages: pageResults.length, strategy: "offset_complete" } };
  };

  const captureReadablePrefix = async (label: string, filters: Partition["filters"],
    knownFirst?: Awaited<ReturnType<typeof fetchPage>>): Promise<Partition> => {
    const first = knownFirst ?? await fetchPage(0, filters);
    const readableTotal = Math.min(first.total, KROGER_MAX_START + KROGER_PAGE_SIZE);
    const starts = offsetPageStarts(readableTotal, KROGER_PAGE_SIZE);
    const rest = await mapWithConcurrency(starts.slice(1), pageConcurrency, (start) => fetchPage(start, filters));
    const pageResults = [first, ...rest];
    if (pageResults.some((page) => page.total !== first.total)) throw new Error(`Baker's ${label} pagination total changed during capture`);
    assertCompleteResultEnvelope(`Baker's ${label}`, readableTotal, pageResults.map((page) => ({ offset: page.start,
      count: page.products.length, ids: page.products.map((product: JsonRecord) => String(product.productId ?? "")) })), KROGER_PAGE_SIZE);
    const products = pageResults.flatMap((page, pageIndex) => page.products.map((product: JsonRecord, resultIndex: number) => ({ product, pageIndex, resultIndex })));
    return { label, filters, total: first.total, pages: pageResults.length, products,
      proof: { label, filters, reportedTotal: first.total, recoveredUnique: products.length,
        requestPages: pageResults.length, strategy: first.total === readableTotal ? "offset_complete" : "offset_prefix" } };
  };

  function unionProductHits(hits: ProductHit[], label: string): ProductHit[] {
    const byId = new Map<string, ProductHit>();
    for (const hit of hits) {
      const id = String(hit.product.productId ?? "");
      if (!id) throw new HeadlessSourceLimitError(`Baker's ${label} returned a product without a stable identity`);
      const prior = byId.get(id);
      if (prior) {
        const identity = (product: JsonRecord) => JSON.stringify([stableProductName(product.description), String(product.brand ?? ""),
          String(product.productPageURI ?? ""), product.items ?? null]);
        if (identity(prior.product) !== identity(hit.product)) throw new HeadlessSourceLimitError(`Baker's ${label} returned conflicting facts for ${id}`);
      } else byId.set(id, hit);
    }
    return [...byId.values()].sort((left, right) => String(left.product.productId).localeCompare(String(right.product.productId)));
  }

  // Baker's is an in-store lane. Kroger's authoritative `ais` filter removes
  // seasonal/catalog-only products that can never qualify for this store price
  // before we prove complete coverage of the eligible envelope.
  const baseFilters: Partition["filters"] = { fulfillment: "ais" };
  const first = await fetchPage(0, baseFilters);
  let products: ProductHit[];
  const partitionProof: JsonRecord[] = [];
  if (first.total <= KROGER_MAX_START + KROGER_PAGE_SIZE) {
    const direct = await captureBounded("direct", baseFilters, first);
    products = direct.products;
    partitionProof.push(direct.proof);
  } else {
    const direct = await captureReadablePrefix("accessible-prefix", baseFilters, first);
    products = direct.products;
    partitionProof.push(direct.proof);
    // Kroger can reorder equally relevant rows between requests. Repeat every
    // legal window concurrently under the exact same query/location/fulfillment
    // filters, then union stable product IDs. This is authoritative recovery,
    // not semantic guessing: every recovered identity came from the base query.
    const repeatStarts = Array.from({ length: 3 }, () => offsetPageStarts(KROGER_MAX_START + KROGER_PAGE_SIZE, KROGER_PAGE_SIZE)).flat();
    const repeated = await mapWithConcurrency(repeatStarts, pageConcurrency, (start) => fetchPage(start, baseFilters));
    const repeatedProducts: ProductHit[] = [];
    for (const [pageIndex, page] of repeated.entries()) {
      if (page.total !== first.total || page.products.some((product: JsonRecord) => !String(product.productId ?? ""))) {
        throw new HeadlessSourceLimitError("Baker's repeated in-store window changed total or omitted a stable identity");
      }
      repeatedProducts.push(...page.products.map((product: JsonRecord, resultIndex: number) => ({ product,
        pageIndex: direct.pages + pageIndex, resultIndex })));
    }
    products = unionProductHits([...products, ...repeatedProducts], "repeated in-store windows");
    partitionProof.push({ label: "repeated-in-store-windows", strategy: "stable_identity_union",
      rounds: 3, loaded: repeatedProducts.length, recoveredUnique: products.length, reportedTotal: first.total });

    if (products.length !== first.total) {
      // A capped envelope can still hide a low-ranked brand. Narrower probes
      // discover case-sensitive brand keys only; each key is then re-queried
      // against the original term and included only in the original count proof.
      const probeModifiers = ["fine", "coarse", "flakes", "grinder", "himalayan", "iodized", "kosher", "smoked",
        "seasoning", "table", "natural", "organic", "pink", "mediterranean", "celtic", "french", "crystals", "shaker",
        "refill", "bulk", "gourmet", "artisan", "classic", "original", "garlic", "truffle", "chips", "popcorn", "crackers",
        "nuts", "chocolate", "caramel", "pretzel", "snack", "roasted", "butter"];
      const probeAttempts = await mapWithConcurrency(probeModifiers, pageConcurrency, async (modifier) => {
        try { return await fetchPage(0, baseFilters, `${modifier} ${query}`); }
        catch (error) {
          if (/omitted a valid pagination total/i.test(String(error instanceof Error ? error.message : error))) return null;
          throw error;
        }
      });
      const probes = probeAttempts.filter((probe): probe is NonNullable<typeof probe> => probe !== null);
      const probeProducts = probes.flatMap((probe) => probe.products);
      const probeBrands = new Set(probeProducts
        .map((product: JsonRecord) => String(product.brand ?? "").trim()).filter(Boolean));
      const queryTokens = searchTokens(query);
      const lexicalUnbranded = probeProducts.filter((product: JsonRecord) => {
        if (String(product.brand ?? "").trim()) return false;
        const nameTokens = new Set(searchTokens(stableProductName(product.description)));
        return String(product.productId ?? "") && queryTokens.every((token) => nameTokens.has(token));
      }).map((product: JsonRecord, resultIndex: number) => ({ product,
        pageIndex: direct.pages + probes.length + resultIndex, resultIndex }));
      products = unionProductHits([...products, ...lexicalUnbranded], "lexically exact unbranded probes");
      partitionProof.push({ label: "brand-discovery-probes", strategy: "brand_keys_only",
        probeCount: probes.length, discoveredBrands: probeBrands.size,
        lexicallyExactUnbranded: lexicalUnbranded.length, recoveredUnique: products.length });
      const queriedBrands = new Set<string>();
      for (let round = 0; products.length !== first.total;) {
        const newBrands = [...new Set([...products.map((hit) => String(hit.product.brand ?? "").trim()).filter(Boolean), ...probeBrands])]
          .filter((brand) => !queriedBrands.has(brand)).sort();
        if (newBrands.length === 0) break;
        newBrands.forEach((brand) => queriedBrands.add(brand));
        const groups = Array.from({ length: Math.ceil(newBrands.length / KROGER_BRANDS_PER_PARTITION) }, (_, index) =>
          newBrands.slice(index * KROGER_BRANDS_PER_PARTITION, (index + 1) * KROGER_BRANDS_PER_PARTITION));
        const partitions = await mapWithConcurrency(groups, pageConcurrency, (group, index) =>
          captureBounded(`brands-${round + 1}-${index + 1}`, { ...baseFilters, brands: group }));
        products = unionProductHits([...products, ...partitions.flatMap((partition) => partition.products)], "partition union");
        partitionProof.push(...partitions.map((partition) => partition.proof));
        round += 1;
      }
    }
    if (products.length !== first.total) throw new HeadlessSourceLimitError(
      `Baker's deterministic in-store brand union recovered ${products.length} of ${first.total} reported products for ${JSON.stringify(query)}`);
  }

  for (const { product, pageIndex, resultIndex } of products) {
      const index = resultIndex;
      const item = Array.isArray(product.items) ? product.items.find((candidate: JsonRecord) => candidate?.price) : null;
      const current = headlessPriceMinor(item?.price?.promo ?? item?.price?.regular);
      const regular = headlessPriceMinor(item?.price?.regular);
      const source = String(product.productPageURI ?? "").split("?", 1)[0];
      const normalized = current === null ? null : capturedRow("bakers", query, { id: String(product.productId ?? item?.itemId ?? ""),
        name: stableProductName(product.description), size: String(item?.size ?? ""),
        url: new URL(source || `/p/${product.productId}`, "https://www.bakersplus.com").href, price: current, regular,
        available: item?.fulfillment?.inStore === true && String(item?.inventory?.stockLevel ?? "").toUpperCase() !== "TEMPORARILY_OUT_OF_STOCK",
        rawAvailability: `${item?.inventory?.stockLevel ?? "unknown"}; inStore=${item?.fulfillment?.inStore === true}`,
        effective: item?.price?.effectiveDate?.value ?? null, expires: item?.price?.expirationDate?.value ?? null }, pageIndex, index, observedAt);
      if (normalized) rows.push(normalized); else excludedResults.push({ productKey: String(product.productId ?? ""), name: String(product.description ?? ""), reason: "incomplete or ambiguous price/size facts" });
  }
  return { rows, total: first.total, examined: products.length, pages: requestPages, excludedResults, partitionProof };
}

async function captureFamilyFareCatalog(file: string, fetchImpl: FetchLike) {
  const store = await jsonFetch("https://api.freshop.ncrcloud.com/1/stores/6401?app_key=family_fare", { headers: { "user-agent": USER_AGENT } }, 1, fetchImpl);
  if (!/^omaha$/i.test(String(store.city ?? ""))) throw new Error("Family Fare store 6401 did not prove Omaha location");
  const snapshot = JSON.parse((await readFile(file, "utf8")).replace(/^\uFEFF/, "")) as { deals?: JsonRecord[] };
  const indexed = new Map<string, JsonRecord>();
  for (const deal of snapshot.deals ?? []) {
    const id = String(deal.product_id ?? "");
    if (id) indexed.set(id, deal);
  }
  if (indexed.size === 0) throw new Error(`Family Fare daily candidate index is empty: ${file}`);
  return [...indexed.values()];
}

async function captureFamilyFareBatch(queries: string[], observedAt: string,
  catalog: Awaited<ReturnType<typeof captureFamilyFareCatalog>>, fetchImpl: FetchLike, concurrency: number): Promise<CaptureRecord[]> {
  const candidatesByQuery = new Map(queries.map((query) => [query,
    catalog.filter((item) => familyFareCatalogMatches(query, stableProductName(item.item)))]));
  const uniqueCandidates = new Map<string, JsonRecord>();
  for (const candidates of candidatesByQuery.values()) {
    for (const candidate of candidates) uniqueCandidates.set(String(candidate.product_id), candidate);
  }
  const details = await mapWithConcurrency([...uniqueCandidates.keys()], concurrency, async (productId) => [productId,
    await jsonFetch(`https://api.freshop.ncrcloud.com/1/products/${encodeURIComponent(productId)}?app_key=family_fare&store_id=6401`,
      { headers: { "user-agent": USER_AGENT } }, 1, fetchImpl)] as const);
  const detailById = new Map(details);
  return queries.map((query) => {
    const rows: JsonRecord[] = []; const excludedResults: JsonRecord[] = [];
    const candidates = candidatesByQuery.get(query) ?? [];
    for (const [index, candidate] of candidates.entries()) {
      const item = detailById.get(String(candidate.product_id))!;
      const current = headlessPriceMinor(item.price); const regular = headlessPriceMinor(item.base_price);
      const rawUrl = String(item.canonical_url ?? "");
      const urlValue = rawUrl ? new URL(rawUrl, "https://www.shopfamilyfare.com").href : "";
      // Freshop's store-scoped /products endpoint is the active shoppable
      // pickup catalog; it omits a separate availability field. A row is
      // eligible only when that current store-6401 response supplies its own
      // stable identity, canonical product URL, and current package price.
      const available = Boolean(item.id && urlValue && current !== null && /^available$/i.test(String(item.status ?? "")));
      const normalized = current === null ? null : capturedRow("family-fare", query, { id: String(item.id ?? ""), name: stableProductName(item.name),
        size: String(item.size ?? ""), url: urlValue, price: current, regular, available,
        rawAvailability: available ? "Freshop store 6401 available" : "Freshop did not prove current availability" }, 0, index, observedAt);
      if (normalized) rows.push(normalized); else excludedResults.push({ productKey: String(item.id ?? ""), name: String(item.name ?? ""), reason: "incomplete, ambiguous, or unavailable Freshop result" });
    }
    // The local index lookup is still one complete examined result envelope when
    // no candidate IDs match. Coverage requires a positive page count so a true
    // empty result can advance to independent QA instead of retrying forever.
    return { query, rows, total: candidates.length, examined: candidates.length, pages: 1, excludedResults };
  });
}

async function captureHyVee(query: string, observedAt: string, fetchImpl: FetchLike, pageConcurrency: number) {
  const rows: JsonRecord[] = []; const excludedResults: JsonRecord[] = [];
  const pageSize = 90;
  // A single retailer search view owns every page in this result envelope. QA
  // receives a different ID because it calls this function in a later pass.
  const pageViewId = crypto.randomUUID();
  const fetchPage = async (page: number) => {
    const body = { pageNumber: page, pageSize: 90, searchFilters: [], searchTerm: query, sortDirection: "RELEVANCE",
      storeId: 1465, pageViewId };
    const response = await jsonFetch("https://www.hy-vee.com/aisles-online/api/search/products", { method: "POST",
      headers: { "content-type": "application/json", "user-agent": USER_AGENT, "x-hy-vee-correlation-id": crypto.randomUUID() }, body: JSON.stringify(body) }, 2, fetchImpl);
    const items = Array.isArray(response.results) ? response.results : [];
    let pagesTotal = Number(response.meta?.pagination?.pagesTotal ?? 0); const total = Number(response.meta?.pagination?.total ?? -1);
    // Hy-Vee reports a complete empty search as total=0/pagesTotal=0 even
    // though page 1 was fetched successfully. Treat that as one examined page
    // so a true no-match can proceed to independent QA.
    if (total === 0 && pagesTotal === 0) pagesTotal = 1;
    if (!Number.isInteger(pagesTotal) || pagesTotal < 1 || !Number.isInteger(total) || total < 0) throw new Error("Hy-Vee omitted pagination totals");
    return { page, pagesTotal, total, items };
  };
  const first = await fetchPage(1);
  const remainingPages = Array.from({ length: Math.max(0, first.pagesTotal - 1) }, (_, index) => index + 2);
  const rest = await mapWithConcurrency(remainingPages, pageConcurrency, (page) => fetchPage(page));
  const pageResults = [first, ...rest];
  if (pageResults.some((page) => page.total !== first.total || page.pagesTotal !== first.pagesTotal)) throw new Error("Hy-Vee pagination totals changed during capture");
  assertCompleteResultEnvelope("Hy-Vee", first.total, pageResults.map((result) => ({ offset: (result.page - 1) * pageSize,
    count: result.items.length, ids: result.items.map((item: JsonRecord) => String(item.id ?? "")) })), pageSize);
  for (const result of pageResults) {
    const { items, page } = result;
    for (const [index, item] of items.entries()) {
      const current = headlessPriceMinor(item.pricing?.tagPriceValue); const regular = headlessPriceMinor(item.pricing?.basePriceValue ?? item.pricing?.regularPriceValue);
      const name = stableProductName(item.description);
      const normalized = current === null ? null : capturedRow("hy-vee", query, { id: String(item.id ?? ""), name,
        size: String(item.unitOfMeasure ?? ""), url: `https://www.hy-vee.com/aisles-online/p/${item.id}/${slug(name)}`,
        price: current, regular, available: item.isEcommerceActive === true,
        rawAvailability: item.isEcommerceActive === true ? "Store 1465 ecommerce active" : "Store 1465 inactive" }, page - 1, index, observedAt);
      if (normalized) rows.push(normalized); else excludedResults.push({ productKey: String(item.id ?? ""), name, reason: "incomplete, ambiguous, discounted-without-dates, or unavailable Hy-Vee result" });
    }
  }
  return { rows, total: first.total, examined: pageResults.reduce((sum, page) => sum + page.items.length, 0), pages: first.pagesTotal, excludedResults };
}

export async function captureHeadlessDiscovery(store: HeadlessStore, terms: string[], file: string,
  options: HeadlessCaptureOptions = {}): Promise<AdapterChunk> {
  if (!(store in STORE) || terms.length < 1 || terms.length > 50) throw new Error("headless capture requires one supported store and 1-50 terms");
  const observedAt = new Date().toISOString();
  const fetchImpl = concurrencyLimitedFetch(options.fetchImpl ?? fetch, options.pageConcurrency ?? DEFAULT_PAGE_CONCURRENCY);
  const termConcurrency = options.termConcurrency ?? DEFAULT_TERM_CONCURRENCY[store];
  const pageConcurrency = options.pageConcurrency ?? DEFAULT_PAGE_CONCURRENCY;
  const queries = [...new Set(terms.map((term) => term.trim()).filter(Boolean))];
  const token = store === "bakers" ? await krogerToken(options.krogerCredentialsFile ?? path.resolve("..", "grocery", ".krogerkey"), fetchImpl) : null;
  const records: CaptureRecord[] = store === "family-fare"
    ? await captureFamilyFareBatch(queries, observedAt,
      await captureFamilyFareCatalog(options.familyFareCatalogFile
        ?? path.resolve("..", "grocery", "out", "regular", `family-fare-regular-${new Date().toISOString().slice(0, 10)}.json`), fetchImpl),
      fetchImpl, termConcurrency)
    : await mapWithConcurrency(queries, termConcurrency, async (query) => {
      try {
        return { query, ...(store === "bakers" ? await captureBakers(query, token!, observedAt, fetchImpl, pageConcurrency)
          : await captureHyVee(query, observedAt, fetchImpl, pageConcurrency)) };
      } catch (error) {
        return { query, rows: [], total: 0, examined: 0, pages: 0, excludedResults: [],
          failure: String(error instanceof Error ? error.message : error).slice(0, 2000) };
      }
    });
  const config = STORE[store];
  const chunk: AdapterChunk = { version: 2, phase: "discovery", store,
    canary: { evidenceUrl: config.evidenceUrl, observedAt, locationVerified: true, priceModeVerified: true },
    terms: records.map((record) => ({ query: record.query, outcome: record.failure ? "rejected" : record.rows.length ? "success" : "empty",
      rowCount: record.rows.length, attempts: 1, startedAt: observedAt, finishedAt: new Date().toISOString(),
      retrieval: { targetResultCount: record.total, loadedResultCount: record.examined,
        availableResultCount: record.total, pageCount: record.pages, hasMoreResults: false,
        termination: record.failure ? "error" : "end-of-results",
        ...(record.partitionProof ? { partitionProof: record.partitionProof } : {}) },
      ...(record.failure ? { reason: record.failure }
        : record.excludedResults.length ? { reason: `${record.excludedResults.length} source result(s) explicitly excluded`, excludedResults: record.excludedResults } : {}) })),
    rows: records.flatMap((record) => record.rows) };
  await writeFile(file, `${JSON.stringify(chunk)}\n`, "utf8");
  return chunk;
}

export function claimSearchTerms(claims: ClaimedCheck[]): string[] {
  return [...new Set(claims.flatMap((claim) => {
    const proposal = JSON.parse(claim.commodity_proposal_json) as { searchTerms?: string[] };
    return proposal.searchTerms ?? [];
  }).map((term) => term.trim()).filter(Boolean))];
}

export function matchesFrozenWinner(row: JsonRecord, captured: JsonRecord): boolean {
  return String(row.url) === String(captured.sourceUrl)
    && String(row.name ?? row.n ?? "") === String(captured.productName ?? "")
    && String(row.size ?? "") === String(captured.packageText ?? "")
    && Number(row._capture?.offer?.purchasePriceMinor) === Number(captured.packagePriceMinor);
}

function frozenWinnerKey(value: { sourceUrl?: unknown; url?: unknown; productName?: unknown; name?: unknown; n?: unknown;
  packageText?: unknown; size?: unknown; packagePriceMinor?: unknown; _capture?: JsonRecord }): string {
  return JSON.stringify([String(value.sourceUrl ?? value.url ?? ""), String(value.productName ?? value.name ?? value.n ?? ""),
    String(value.packageText ?? value.size ?? ""), Number(value.packagePriceMinor ?? value._capture?.offer?.purchasePriceMinor)]);
}

export async function captureHeadlessVerification(store: HeadlessStore, claims: ClaimedCheck[], file: string,
  options: HeadlessCaptureOptions = {}): Promise<AdapterChunk> {
  const temporary = `${file}.discovery.json`;
  const discovery = await captureHeadlessDiscovery(store, claimSearchTerms(claims), temporary, options);
  const rows = discovery.rows ?? [];
  const rowsByFrozenWinner = new Map(rows.map((row) => [frozenWinnerKey(row), row]));
  const verifications: JsonRecord[] = [];
  for (const claim of claims) {
    const captured = JSON.parse(String(claim.capture_result_json ?? "null")) as JsonRecord | null;
    if (captured?.outcome !== "priced") continue;
    const match = rowsByFrozenWinner.get(frozenWinnerKey(captured)) as JsonRecord | undefined;
    verifications.push({ rowKey: claim.id, discoveryHash: String((claim as JsonRecord).candidate_set_hash ?? ""),
      observedAt: discovery.canary.observedAt, outcome: match ? "observed" : "missing", productKey: captured.sourceUrl,
      ...(match ? { name: match.name ?? match.n, sizeText: match.size,
        purchasePriceMinor: match._capture?.offer?.purchasePriceMinor, truth: match._capture } : { reason: "frozen winner absent from independent API result envelope" }) });
  }
  const verification: AdapterChunk = { version: 2, phase: "verification", store, canary: discovery.canary, verifications };
  await writeFile(file, `${JSON.stringify(verification)}\n`, "utf8");
  return verification;
}

export type { HeadlessStore };
