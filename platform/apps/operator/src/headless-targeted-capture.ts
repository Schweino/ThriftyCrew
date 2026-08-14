import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import type { AdapterChunk, ClaimedCheck } from "./ingredient-targeted-capture";

type HeadlessStore = "bakers" | "family-fare" | "hy-vee";
type JsonRecord = Record<string, any>;

const STORE = {
  bakers: { location: "Baker's Saddle Creek", locationId: "61500319", priceMode: "in_store", seller: "Baker's",
    evidenceUrl: "https://www.bakersplus.com/stores/grocery/ne/omaha/bakers-saddle-creek/615/00319" },
  "family-fare": { location: "Family Fare 50th & Grover", locationId: "6401", priceMode: "pickup", seller: "Family Fare",
    evidenceUrl: "https://www.shopfamilyfare.com/store/family-fare/products" },
  "hy-vee": { location: "Omaha Hy-Vee #01", locationId: "1465", priceMode: "in_store", seller: "Hy-Vee",
    evidenceUrl: "https://www.hy-vee.com/aisles-online/search" },
} as const;

const USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/148 Safari/537.36";

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

async function jsonFetch(url: string, init: RequestInit = {}, attempts = 2): Promise<JsonRecord> {
  let last: unknown;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await fetch(url, { ...init, signal: AbortSignal.timeout(30_000) });
      if (response.status === 429) throw new Error(`source throttled HTTP 429: ${new URL(url).hostname}`);
      if (!response.ok) throw new Error(`source returned HTTP ${response.status}: ${new URL(url).hostname}`);
      return await response.json() as JsonRecord;
    } catch (error) {
      last = error;
      if (/HTTP 429|HTTP 4\d\d/.test(String(error)) || attempt === attempts) break;
      await new Promise((resolve) => setTimeout(resolve, attempt * 500));
    }
  }
  throw last instanceof Error ? last : new Error(String(last));
}

async function krogerToken(credentialsFile: string): Promise<string> {
  const credentials = JSON.parse(await readFile(credentialsFile, "utf8")) as { client_id?: string; client_secret?: string };
  if (!credentials.client_id || !credentials.client_secret) throw new Error("Kroger product API credentials are missing");
  const authorization = Buffer.from(`${credentials.client_id}:${credentials.client_secret}`).toString("base64");
  const response = await jsonFetch("https://api.kroger.com/v1/connect/oauth2/token", {
    method: "POST", headers: { authorization: `Basic ${authorization}`, "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&scope=product.compact",
  }, 1);
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

async function captureBakers(query: string, token: string, observedAt: string) {
  const rows: JsonRecord[] = []; const excludedResults: JsonRecord[] = [];
  let start = 0; let total = 0; let pages = 0;
  do {
    const url = new URL("https://api.kroger.com/v1/products");
    url.searchParams.set("filter.locationId", STORE.bakers.locationId); url.searchParams.set("filter.term", query);
    url.searchParams.set("filter.limit", "50"); url.searchParams.set("filter.start", String(start));
    const response = await jsonFetch(url.href, { headers: { authorization: `Bearer ${token}`, accept: "application/json" } });
    const products = Array.isArray(response.data) ? response.data : [];
    total = Number(response.meta?.pagination?.total ?? products.length); pages += 1;
    for (const [index, product] of products.entries()) {
      const item = Array.isArray(product.items) ? product.items.find((candidate: JsonRecord) => candidate?.price) : null;
      const current = headlessPriceMinor(item?.price?.promo ?? item?.price?.regular);
      const regular = headlessPriceMinor(item?.price?.regular);
      const source = String(product.productPageURI ?? "").split("?", 1)[0];
      const normalized = current === null ? null : capturedRow("bakers", query, { id: String(product.productId ?? item?.itemId ?? ""),
        name: stableProductName(product.description), size: String(item?.size ?? ""),
        url: new URL(source || `/p/${product.productId}`, "https://www.bakersplus.com").href, price: current, regular,
        available: item?.fulfillment?.inStore === true && String(item?.inventory?.stockLevel ?? "").toUpperCase() !== "TEMPORARILY_OUT_OF_STOCK",
        rawAvailability: `${item?.inventory?.stockLevel ?? "unknown"}; inStore=${item?.fulfillment?.inStore === true}`,
        effective: item?.price?.effectiveDate?.value ?? null, expires: item?.price?.expirationDate?.value ?? null }, pages - 1, index, observedAt);
      if (normalized) rows.push(normalized); else excludedResults.push({ productKey: String(product.productId ?? ""), name: String(product.description ?? ""), reason: "incomplete or ambiguous price/size facts" });
    }
    start += products.length;
    if (products.length === 0) break;
  } while (start < total && pages < 20);
  if (start < total) throw new Error(`Baker's pagination stopped at ${start} of ${total}`);
  return { rows, total, pages, excludedResults };
}

async function captureFamilyFare(query: string, observedAt: string) {
  const store = await jsonFetch("https://api.freshop.ncrcloud.com/1/stores/6401?app_key=family_fare", { headers: { "user-agent": USER_AGENT } }, 1);
  if (!/^omaha$/i.test(String(store.city ?? ""))) throw new Error("Family Fare store 6401 did not prove Omaha location");
  const rows: JsonRecord[] = []; const excludedResults: JsonRecord[] = [];
  let offset = 0; let pages = 0; let total: number | null = null;
  do {
    const url = new URL("https://api.freshop.ncrcloud.com/1/products");
    for (const [key, value] of Object.entries({ app_key: "family_fare", store_id: "6401", q: query, limit: "50", offset: String(offset), fields: "id,name,size,price,base_price,unit_price,canonical_url" })) url.searchParams.set(key, value);
    const response = await jsonFetch(url.href, { headers: { "user-agent": USER_AGENT } }, 1);
    const items = Array.isArray(response.items) ? response.items : [];
    const reported = response.total ?? response.total_count ?? response.meta?.pagination?.total;
    if (reported !== undefined && reported !== null) total = Number(reported);
    pages += 1;
    for (const [index, item] of items.entries()) {
      const current = headlessPriceMinor(item.price); const regular = headlessPriceMinor(item.base_price);
      const rawUrl = String(item.canonical_url ?? "");
      const urlValue = rawUrl ? new URL(rawUrl, "https://www.shopfamilyfare.com").href : "";
      // Freshop's store-scoped /products endpoint is the active shoppable
      // pickup catalog; it omits a separate availability field. A row is
      // eligible only when that current store-6401 response supplies its own
      // stable identity, canonical product URL, and current package price.
      const available = Boolean(item.id && urlValue && current !== null);
      const normalized = current === null ? null : capturedRow("family-fare", query, { id: String(item.id ?? ""), name: stableProductName(item.name),
        size: String(item.size ?? ""), url: urlValue, price: current, regular, available,
        rawAvailability: available ? "Freshop store 6401 available" : "Freshop did not prove current availability" }, pages - 1, index, observedAt);
      if (normalized) rows.push(normalized); else excludedResults.push({ productKey: String(item.id ?? ""), name: String(item.name ?? ""), reason: "incomplete, ambiguous, or unavailable Freshop result" });
    }
    offset += items.length;
    if (items.length < 50) { if (total === null) total = offset; break; }
    if (items.length === 0) break;
  } while ((total === null || offset < total) && pages < 20);
  if (total === null || offset < total) throw new Error(`Family Fare pagination did not prove end of results (${offset}/${total ?? "unknown"})`);
  return { rows, total, pages, excludedResults };
}

async function captureHyVee(query: string, observedAt: string) {
  const rows: JsonRecord[] = []; const excludedResults: JsonRecord[] = [];
  let page = 1; let pagesTotal = 1; let total = 0;
  do {
    const body = { pageNumber: page, pageSize: 90, searchFilters: [], searchTerm: query, sortDirection: "RELEVANCE",
      storeId: 1465, pageViewId: crypto.randomUUID() };
    const response = await jsonFetch("https://www.hy-vee.com/aisles-online/api/search/products", { method: "POST",
      headers: { "content-type": "application/json", "user-agent": USER_AGENT, "x-hy-vee-correlation-id": crypto.randomUUID() }, body: JSON.stringify(body) });
    const items = Array.isArray(response.results) ? response.results : [];
    pagesTotal = Number(response.meta?.pagination?.pagesTotal ?? 0); total = Number(response.meta?.pagination?.total ?? -1);
    if (!Number.isInteger(pagesTotal) || pagesTotal < 1 || !Number.isInteger(total) || total < 0) throw new Error("Hy-Vee omitted pagination totals");
    for (const [index, item] of items.entries()) {
      const current = headlessPriceMinor(item.pricing?.tagPriceValue); const regular = headlessPriceMinor(item.pricing?.basePriceValue ?? item.pricing?.regularPriceValue);
      const name = stableProductName(item.description);
      const normalized = current === null ? null : capturedRow("hy-vee", query, { id: String(item.id ?? ""), name,
        size: String(item.unitOfMeasure ?? ""), url: `https://www.hy-vee.com/aisles-online/p/${item.id}/${slug(name)}`,
        price: current, regular, available: item.isEcommerceActive === true,
        rawAvailability: item.isEcommerceActive === true ? "Store 1465 ecommerce active" : "Store 1465 inactive" }, page - 1, index, observedAt);
      if (normalized) rows.push(normalized); else excludedResults.push({ productKey: String(item.id ?? ""), name, reason: "incomplete, ambiguous, discounted-without-dates, or unavailable Hy-Vee result" });
    }
    page += 1;
  } while (page <= pagesTotal && page <= 20);
  if (page <= pagesTotal) throw new Error(`Hy-Vee pagination stopped before page ${pagesTotal}`);
  return { rows, total, pages: pagesTotal, excludedResults };
}

export async function captureHeadlessDiscovery(store: HeadlessStore, terms: string[], file: string,
  options: { krogerCredentialsFile?: string } = {}): Promise<AdapterChunk> {
  if (!(store in STORE) || terms.length < 1 || terms.length > 50) throw new Error("headless capture requires one supported store and 1-50 terms");
  const observedAt = new Date().toISOString();
  const token = store === "bakers" ? await krogerToken(options.krogerCredentialsFile ?? path.resolve("..", "grocery", ".krogerkey")) : null;
  const records: Array<{ query: string; rows: JsonRecord[]; total: number; pages: number; excludedResults: JsonRecord[] }> = [];
  for (const query of [...new Set(terms.map((term) => term.trim()).filter(Boolean))]) {
    const captured = store === "bakers" ? await captureBakers(query, token!, observedAt)
      : store === "family-fare" ? await captureFamilyFare(query, observedAt) : await captureHyVee(query, observedAt);
    records.push({ query, ...captured });
  }
  const config = STORE[store];
  const chunk: AdapterChunk = { version: 2, phase: "discovery", store,
    canary: { evidenceUrl: config.evidenceUrl, observedAt, locationVerified: true, priceModeVerified: true },
    terms: records.map((record) => ({ query: record.query, outcome: record.rows.length ? "success" : "empty",
      rowCount: record.rows.length, attempts: 1, startedAt: observedAt, finishedAt: new Date().toISOString(),
      retrieval: { targetResultCount: record.total, loadedResultCount: record.rows.length,
        availableResultCount: record.total, pageCount: record.pages, hasMoreResults: false, termination: "end-of-results" },
      ...(record.excludedResults.length ? { reason: `${record.excludedResults.length} source result(s) explicitly excluded`, excludedResults: record.excludedResults } : {}) })),
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

export async function captureHeadlessVerification(store: HeadlessStore, claims: ClaimedCheck[], file: string,
  options: { krogerCredentialsFile?: string } = {}): Promise<AdapterChunk> {
  const temporary = `${file}.discovery.json`;
  const discovery = await captureHeadlessDiscovery(store, claimSearchTerms(claims), temporary, options);
  const rows = discovery.rows ?? [];
  const verifications: JsonRecord[] = [];
  for (const claim of claims) {
    const captured = JSON.parse(String(claim.capture_result_json ?? "null")) as JsonRecord | null;
    if (captured?.outcome !== "priced") continue;
    const match = rows.find((row) => String(row.url) === String(captured.sourceUrl)) as JsonRecord | undefined;
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
