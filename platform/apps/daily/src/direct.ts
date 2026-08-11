import { BROWSER_CAPTURE_ACCURACY_CUTOVER, CAPTURE_SEMANTICS_CUTOVER, browserCaptureSessionSchema, type BrowserCaptureSession, type DirectCaptureArtifact, type ObservationInput, type PriceSemantics, type ProductIdentity, type SourceSchemaFingerprint } from "@thriftycrew/contracts";
import { buildBrowserCaptureAccuracy, digestHex, expectedProductIdentityFingerprint, normalizeName, stableJson } from "@thriftycrew/domain";

type StoreKey = "aldi" | "bakers" | "family-fare" | "fareway" | "hy-vee" | "sams" | "walmart";
interface RegularDocument {
  store?: string;
  price_mode?: string;
  mode_verified?: boolean | string;
  source?: string;
  generated?: string;
  coverage_mode?: string;
  capture_terms?: Array<Record<string, unknown>>;
  empty_terms?: unknown[];
  deals?: Array<Record<string, unknown>>;
  capture_session?: unknown;
  location_id?: string | number;
  store_label?: string;
}
export interface CaptureAttestation {
  store: string;
  market: string;
  priceMode: string;
  verifiedAt: string;
  evidenceUrl: string;
  statement: string;
  marketVerified: boolean;
  locationVerified: boolean;
  priceModeVerified: boolean;
  screenshotSha256?: string[];
  captureSessionHash?: string;
}

const STORE_ALIASES: Record<string, StoreKey> = {
  aldi: "aldi", bakers: "bakers", "baker's": "bakers", "family-fare": "family-fare", "family fare": "family-fare",
  fareway: "fareway", hyvee: "hy-vee", "hy-vee": "hy-vee", sams: "sams", "sam's club": "sams", walmart: "walmart",
};
const HEADLESS_PRICE_MODE: Record<StoreKey, string> = {
  aldi: "in_store", bakers: "in_store", "family-fare": "pickup", fareway: "in_store", "hy-vee": "in_store", sams: "club", walmart: "pickup",
};

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

const WINDOWS_1252_BYTES = new Map<number, number>([
  [0x20ac, 0x80], [0x201a, 0x82], [0x0192, 0x83], [0x201e, 0x84], [0x2026, 0x85], [0x2020, 0x86],
  [0x2021, 0x87], [0x02c6, 0x88], [0x2030, 0x89], [0x0160, 0x8a], [0x2039, 0x8b], [0x0152, 0x8c],
  [0x017d, 0x8e], [0x2018, 0x91], [0x2019, 0x92], [0x201c, 0x93], [0x201d, 0x94], [0x2022, 0x95],
  [0x2013, 0x96], [0x2014, 0x97], [0x02dc, 0x98], [0x2122, 0x99], [0x0161, 0x9a], [0x203a, 0x9b],
  [0x0153, 0x9c], [0x017e, 0x9e], [0x0178, 0x9f],
]);

function repairCaptureMojibake(value: string): string {
  let current = value;
  for (let pass = 0; pass < 4 && /[ÃÂâ]/.test(current); pass += 1) {
    const bytes: number[] = [];
    let encodable = true;
    for (const character of current) {
      const code = character.codePointAt(0)!;
      const byte = WINDOWS_1252_BYTES.get(code) ?? (code <= 0xff ? code : undefined);
      if (byte === undefined) { encodable = false; break; }
      bytes.push(byte);
    }
    if (!encodable) break;
    try {
      const repaired = new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(bytes));
      if (repaired === current || repaired.includes("\ufffd")) break;
      current = repaired;
    } catch { break; }
  }
  return current;
}

function identifierValue(value: unknown): string | undefined {
  const text = stringValue(value);
  if (text) return text;
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? String(value) : undefined;
}

function numberValue(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value !== "string") return undefined;
  const normalized = value.trim().replace(/,/g, "");
  const match = normalized.match(/^\$?([0-9]+(?:\.[0-9]+)?)$/);
  if (!match) return undefined;
  const parsed = Number(match[1]);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function safeUrl(value: unknown): string | undefined {
  const text = stringValue(value);
  if (!text) return undefined;
  try { const url = new URL(text); return url.protocol === "https:" ? url.href : undefined; } catch { return undefined; }
}

function taxonomy(row: Record<string, unknown>, store: StoreKey): string | undefined {
  const explicit = [row.taxonomy_path, row.store_category, row.store_aisle, row.department, row.category].map(stringValue).filter((item): item is string => Boolean(item));
  if (explicit.length) return [...new Set(explicit)].join("/");
  if (store !== "family-fare") return undefined;
  const productUrl = safeUrl(row.canonical_url);
  if (!productUrl) return undefined;
  const segments = new URL(productUrl).pathname.split("/").filter(Boolean);
  const shop = segments.indexOf("shop");
  const product = segments.lastIndexOf("p");
  return shop >= 0 && product > shop + 1 ? segments.slice(shop + 1, product).join("/") : undefined;
}

function basis(sizeText: string): { unit: ObservationInput["normalizedBasisUnit"]; quantityMicros: number; packageCount: number } | undefined {
  const normalized = sizeText.toLowerCase().replace(/fluid ounces?/g, "fl oz").replace(/ounces?/g, "oz").replace(/pounds?/g, "lb").replace(/counts?/g, "ct").trim();
  const pack = normalized.match(/^(\d+)\s*[x\u00d7]\s*([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|oz|lb|ml|l|liter|g|gram|kg|ct|ea|pk)\b/);
  const match = pack ?? normalized.match(/([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|oz|lb|ml|l|liter|g|gram|kg|ct|ea|pk|dozen|gal|gallon|qt|pt|each)\b/);
  if (!match) {
    if (/^(lb|per lb)$/.test(normalized)) return { unit: "lb", quantityMicros: 1_000_000, packageCount: 1 };
    if (normalized === "dozen") return { unit: "dozen", quantityMicros: 1_000_000, packageCount: 1 };
    if (/^(each|ea)$/.test(normalized)) return { unit: "each", quantityMicros: 1_000_000, packageCount: 1 };
    return undefined;
  }
  const packageCount = pack ? Number(match[1]) : 1;
  const quantity = Number(match[pack ? 2 : 1]) * packageCount;
  const rawUnit = (match[pack ? 3 : 2] ?? "").replace(/\s/g, "");
  const unit: ObservationInput["normalizedBasisUnit"] = rawUnit === "floz" ? "fl_oz"
    : rawUnit === "l" || rawUnit === "liter" ? "liter"
    : rawUnit === "g" || rawUnit === "gram" ? "gram"
    : rawUnit === "ct" || rawUnit === "ea" || rawUnit === "pk" ? "each"
    : rawUnit === "gallon" ? "gal"
    : rawUnit as ObservationInput["normalizedBasisUnit"];
  return { unit, quantityMicros: Math.max(1, Math.round(quantity * 1_000_000)), packageCount };
}

function consumerPackageBasis(name: string | undefined, parsed: ReturnType<typeof basis>): ReturnType<typeof basis> {
  if (!parsed || parsed.unit !== "each" || parsed.quantityMicros <= 1_000_000) return parsed;
  const normalized = name?.toLowerCase() ?? "";
  if (/\baluminum\s+foil\b/.test(normalized) && /\bsq\.?\s*ft\b|square\s+feet/.test(normalized)) {
    return { unit: "each", quantityMicros: 1_000_000, packageCount: 1 };
  }
  if (/\b(?:lettuce|iceberg|romaine)\b/.test(normalized) && /\bhead\b/.test(normalized) && parsed.quantityMicros >= 12_000_000) {
    return { unit: "each", quantityMicros: 1_000_000, packageCount: 1 };
  }
  if (/\bbread\b/.test(normalized) && /\bloaf\b/.test(normalized)) {
    return { unit: "each", quantityMicros: 1_000_000, packageCount: 1 };
  }
  if (/\b(?:paper\s+towels?|toilet\s+paper|bath\s+tissue)\b/.test(normalized)) {
    const counts = [...normalized.matchAll(/(\d+)\s*(?:ct|count|rolls?)\b/g)].map((match) => Number(match[1])).filter((count) => count > 0 && count <= 100);
    const count = counts.at(-1);
    if (count) return { unit: "each", quantityMicros: count * 1_000_000, packageCount: count };
  }
  return parsed;
}

type BasisOption = NonNullable<ObservationInput["basisOptions"]>[number];

function optionUnit(raw: string): ObservationInput["normalizedBasisUnit"] | undefined {
  const unit = raw.toLowerCase().replace(/\./g, "").replace(/\s/g, "");
  if (unit === "floz" || unit === "fluidounce" || unit === "fluidounces") return "fl_oz";
  if (unit === "oz" || unit === "ounce" || unit === "ounces") return "oz";
  if (unit === "lb" || unit === "lbs" || unit === "pound" || unit === "pounds") return "lb";
  if (unit === "ml") return "ml";
  if (unit === "l" || unit === "liter" || unit === "liters") return "liter";
  if (unit === "g" || unit === "gram" || unit === "grams") return "gram";
  if (unit === "kg") return "kg";
  if (unit === "gal" || unit === "gallon" || unit === "gallons") return "gal";
  if (unit === "qt") return "qt";
  if (unit === "pt") return "pt";
  return undefined;
}

function packageBasisOptions(sizeText: string, name: string, purchasePriceMinor: number): BasisOption[] {
  const options: BasisOption[] = [];
  const seen = new Set<string>();
  const add = (unit: ObservationInput["normalizedBasisUnit"], quantity: number, source: string) => {
    const quantityMicros = Math.round(quantity * 1_000_000);
    if (!Number.isSafeInteger(quantityMicros) || quantityMicros <= 0) return;
    const key = `${unit}:${quantityMicros}`;
    if (seen.has(key)) return;
    seen.add(key);
    options.push({
      unit,
      quantityMicros,
      perUnitMicros: Math.round((purchasePriceMinor * 10_000 * 1_000_000) / quantityMicros),
      source,
    });
  };
  const normalizeMeasureText = (text: string): string => text.toLowerCase()
    .replace(/fluid ounces?/g, "fl oz")
    .replace(/(^|[^\d])\.(\d+)/g, (_match, prefix: string, digits: string) => `${prefix}0.${digits}`);
  const normalizedSize = normalizeMeasureText(sizeText);
  const normalizedName = normalizeMeasureText(name);
  // Package names often state container capacity ("13 gallon, 110 ct.") rather than contents.
  // Limit name-derived multiplication to mass and small-volume contents units; standalone captured
  // sizes still retain gallons/quarts/pints through basis().
  const measure = "(fl\\.?\\s*oz|ounces?|oz|pounds?|lbs?|lb|ml|liters?|liter|l|grams?|gram|g|kg)";

  for (const text of [normalizedSize, normalizedName]) {
    for (const match of text.matchAll(new RegExp(`(\\d+(?:\\.\\d+)?)\\s*(?:ct|count|pk|pack)s?\\s*(x|of)?\\s*(\\d+(?:\\.\\d+)?)\\s*${measure}\\b`, "g"))) {
      const unit = optionUnit(match[4]!);
      // A large count followed by a package weight ("65 ct 3.45 lb")
      // describes total package weight, not 65 packages weighing 3.45 lb
      // apiece. Explicit x/of notation remains authoritative.
      const explicitMultiplier = Boolean(match[2]);
      if (unit && (explicitMultiplier || !["lb", "kg"].includes(unit))) add(unit, Number(match[1]) * Number(match[3]), "count-times-measure");
    }
    for (const match of text.matchAll(new RegExp(`(\\d+(?:\\.\\d+)?)\\s*${measure}\\s*(?:each|ea|cans?|bottles?|pouches?|cups?)[\\s,.-]+(\\d+(?:\\.\\d+)?)\\s*(?:ct|count|pk|pack)s?\\b`, "g"))) {
      const unit = optionUnit(match[2]!);
      if (unit) add(unit, Number(match[1]) * Number(match[3]), "measure-times-count");
    }
    for (const match of text.matchAll(new RegExp(`(\\d+(?:\\.\\d+)?)\\s*${measure}\\b`, "g"))) {
      const unit = optionUnit(match[2]!);
      if (unit) add(unit, Number(match[1]), "stated-measure");
    }
  }

  const parsed = basis(sizeText);
  if (parsed) add(parsed.unit, parsed.quantityMicros / 1_000_000, "captured-size");
  for (const text of [normalizedSize, normalizedName]) {
    for (const match of text.matchAll(/(\d+(?:\.\d+)?)\s*(?:ct|count|pk|pack)s?\b/g)) {
      add("each", Number(match[1]), "stated-package-count");
    }
  }
  return options.slice(0, 12);
}

function omahaDayStart(date: string): string {
  const [year, month, day] = date.split("-").map(Number);
  if (!year || !month || !day) return new Date(date).toISOString();
  const guess = Date.UTC(year, month - 1, day, 12);
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: "America/Chicago", hour12: false, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" })
    .formatToParts(new Date(guess)).reduce<Record<string, number>>((result, item) => { if (item.type !== "literal") result[item.type] = Number(item.value); return result; }, {});
  const represented = Date.UTC(parts.year!, parts.month! - 1, parts.day!, parts.hour!, parts.minute!, parts.second!);
  // A source date proves the Omaha calendar day, not a wall-clock capture time. Canonicalize it
  // to the start of that local day. Noon made morning jobs claim a future capture and correctly
  // fail the API's five-minute future-skew guard.
  return new Date(Date.UTC(year, month - 1, day) - (represented - guess)).toISOString();
}

function termKey(value: string): string {
  return normalizeName(value).replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 150) || "catalog";
}

function authoredTermLedger(document: RegularDocument): DirectCaptureArtifact["terms"] | undefined {
  if (!Array.isArray(document.capture_terms) || document.capture_terms.length === 0) return undefined;
  const outcomes = new Set(["success", "empty", "rejected", "blocked", "not_attempted"]);
  const terms = document.capture_terms.map((raw, index) => {
    const key = termKey(stringValue(raw.term_key) ?? stringValue(raw.term) ?? `term-${index}`);
    const rawOutcome = stringValue(raw.outcome) ?? "blocked";
    if (!outcomes.has(rawOutcome)) throw new Error(`capture term ${key} has unsupported outcome ${rawOutcome}`);
    const rowCount = numberValue(raw.row_count) ?? numberValue(raw.rowCount) ?? 0;
    if (!Number.isInteger(rowCount) || rowCount < 0) throw new Error(`capture term ${key} has invalid row count`);
    return {
      termKey: key,
      ordinal: Number.isInteger(numberValue(raw.ordinal)) ? Number(numberValue(raw.ordinal)) : index,
      outcome: rawOutcome as DirectCaptureArtifact["terms"][number]["outcome"],
      rowCount,
      ...(stringValue(raw.reason) ? { reason: stringValue(raw.reason)! } : {}),
    };
  });
  if (new Set(terms.map((term) => term.termKey)).size !== terms.length) throw new Error("capture term ledger contains duplicate term keys");
  if (new Set(terms.map((term) => term.ordinal)).size !== terms.length) throw new Error("capture term ledger contains duplicate ordinals");
  return terms.sort((left, right) => left.ordinal - right.ordinal);
}

async function externalKey(row: Record<string, unknown>, index: number): Promise<string> {
  const direct = identifierValue(row.product_id) ?? identifierValue(row.item_id) ?? identifierValue(row.sams_item_id) ?? identifierValue(row.upc) ?? identifierValue(row.sku) ?? safeUrl(row.canonical_url) ?? safeUrl(row.link_url);
  if (direct) return direct.slice(0, 300);
  const identity = {
    name: normalizeName(stringValue(row.item) ?? stringValue(row.name) ?? ""),
    size: normalizeName(stringValue(row.size_raw) ?? stringValue(row.size) ?? ""),
  };
  return `catalog-${(await digestHex(stableJson(identity))).slice(0, 32)}${identity.name ? "" : `-${index}`}`;
}

function digits(value: unknown): string | undefined {
  const normalized = identifierValue(value)?.replace(/\D/g, "");
  return normalized && /^\d{8,14}$/.test(normalized) ? normalized : undefined;
}

async function productIdentity(row: Record<string, unknown>, index: number, name: string, sizeText: string, store: StoreKey): Promise<ProductIdentity> {
  const retailerProductId = (identifierValue(row.product_id) ?? identifierValue(row.item_id) ?? identifierValue(row.sams_item_id))?.slice(0, 300);
  const gtin = digits(row.gtin) ?? digits(row.gtin13) ?? digits(row.gtin14);
  const upc = digits(row.upc);
  const sku = identifierValue(row.sku);
  const canonicalUrl = safeUrl(row.canonical_url) ?? safeUrl(row.link_url);
  const brand = stringValue(row.brand) ?? stringValue(row.brand_name);
  const externalProductKey = await externalKey(row, index);
  if ((store === "walmart" || store === "sams") && retailerProductId && canonicalUrl) {
    const pathSegments = new URL(canonicalUrl).pathname.split("/").filter(Boolean);
    const urlProductId = [...pathSegments].reverse().find((segment) => /^\d{5,}$/.test(segment));
    if (urlProductId && urlProductId !== retailerProductId) throw new Error(`${store} canonical URL product id ${urlProductId} disagrees with retailer product id ${retailerProductId}`);
  }
  const primaryType: ProductIdentity["primaryType"] = retailerProductId ? "retailer_id" : gtin ? "gtin" : upc ? "upc" : sku ? "sku" : canonicalUrl ? "canonical_url" : "synthetic";
  const primaryValue = primaryType === "canonical_url" ? canonicalUrl! : externalProductKey;
  const stableChannels = [retailerProductId, gtin, upc, sku, canonicalUrl].filter(Boolean).length;
  const confidence: ProductIdentity["confidence"] = stableChannels >= 2 ? "strong" : stableChannels === 1 ? "moderate" : "weak";
  const fingerprintInput = { primaryType, primaryValue, ...(retailerProductId ? { retailerProductId } : {}), ...(gtin ? { gtin } : {}), ...(upc ? { upc } : {}), ...(sku ? { sku } : {}), ...(canonicalUrl ? { canonicalUrl } : {}), ...(brand ? { brand } : {}) };
  return {
    primaryType, primaryValue, ...(retailerProductId ? { retailerProductId } : {}), ...(gtin ? { gtin } : {}),
    ...(upc ? { upc } : {}), ...(sku ? { sku } : {}), ...(canonicalUrl ? { canonicalUrl } : {}),
    ...(brand ? { brand } : {}), confidence, fingerprint: await expectedProductIdentityFingerprint(fingerprintInput, name, sizeText),
  };
}

function schemaType(value: unknown): "null" | "boolean" | "number" | "string" | "array" | "object" {
  return value === null || value === undefined ? "null" : Array.isArray(value) ? "array" : typeof value as "boolean" | "number" | "string" | "object";
}

async function sourceSchemaFingerprint(rows: readonly Record<string, unknown>[], document: RegularDocument): Promise<SourceSchemaFingerprint> {
  const observed = new Map<string, Set<ReturnType<typeof schemaType>>>();
  for (const row of rows) for (const [field, value] of Object.entries(row)) {
    const types = observed.get(field) ?? new Set<ReturnType<typeof schemaType>>();
    types.add(schemaType(value));
    observed.set(field, types);
  }
  const activePaths = (candidates: readonly string[]) => [...new Set(rows.flatMap((row) => candidates.find((field) => row[field] !== undefined && row[field] !== null && row[field] !== "") ?? []))].sort();
  if (stringValue(document.generated)) observed.set("$document.generated", new Set(["string"]));
  const identityPaths = activePaths(["product_id", "item_id", "sams_item_id", "upc", "gtin", "sku", "canonical_url", "link_url"]);
  if (identityPaths.length === 0) observed.set("$derived.synthetic_identity", new Set(["string"]));
  const contractFields = {
    identity: identityPaths.length ? identityPaths : ["$derived.synthetic_identity"],
    name: activePaths(["item", "name"]),
    price: activePaths(["current_price", "ad_price"]),
    size: activePaths(["size_raw", "size"]),
    captured_at: activePaths(["as_of"]).concat(stringValue(document.generated) ? ["$document.generated"] : []),
  };
  for (const [logical, paths] of Object.entries(contractFields)) if (paths.length === 0) throw new Error(`accepted source rows do not expose a ${logical} field path`);
  const fieldPaths = [...observed.keys()].sort();
  const observedTypes = Object.fromEntries(fieldPaths.map((field) => [field, [...observed.get(field)!].sort()]));
  const contractShape = Object.fromEntries(Object.entries(contractFields).map(([logical, paths]) => [logical, paths.map((field) => [field, observedTypes[field]?.filter((type) => type !== "null") ?? []])]));
  return {
    version: 1,
    contractFingerprint: await digestHex(stableJson(contractShape)),
    shapeFingerprint: await digestHex(stableJson(observedTypes)),
    contractFields,
    fieldPaths,
    observedTypes,
  };
}

function verifiedUnitPrice(value: unknown): { unit: ObservationInput["normalizedBasisUnit"]; perUnitMicros: number } | undefined {
  const text = stringValue(value)?.toLowerCase().replace(/,/g, "");
  const match = text?.match(/^\$?([0-9]+(?:\.[0-9]+)?)\s*\/\s*(lb|oz|fl\s*oz|ea|each|ct|dozen|gal|gallon|qt|pt)\b/);
  if (!match) return undefined;
  const unit = match[2]!.replace(/\s/g, "") === "floz" ? "fl_oz"
    : match[2] === "ea" || match[2] === "ct" ? "each"
    : match[2] === "gallon" ? "gal"
    : match[2] as ObservationInput["normalizedBasisUnit"];
  return { unit, perUnitMicros: Math.round(Number(match[1]) * 1_000_000) };
}

export async function buildRegularCapture(
  storeInput: string,
  document: RegularDocument,
  attestation?: CaptureAttestation,
  captureClient: "headless" | "browser" = "headless",
): Promise<DirectCaptureArtifact> {
  const store = STORE_ALIASES[storeInput.toLowerCase()] ?? STORE_ALIASES[(document.store ?? "").toLowerCase()];
  if (!store) throw new Error(`unsupported store ${storeInput}`);
  if (captureClient === "browser" && !attestation) throw new Error("browser captures require a market, location, and price-mode attestation");
  const captureSession: BrowserCaptureSession | undefined = captureClient === "browser" ? browserCaptureSessionSchema.parse(document.capture_session) : undefined;
  if (captureClient === "browser" && !captureSession) throw new Error("browser captures require an immutable capture-session manifest");
  if (attestation) {
    const attestedStore = STORE_ALIASES[attestation.store.toLowerCase()];
    if (attestedStore !== store) throw new Error(`capture attestation is for ${attestation.store}, not ${store}`);
    if (!/^omaha(?:,?\s*(?:ne|nebraska))?$/i.test(attestation.market.trim())) throw new Error("capture attestation must verify the Omaha market");
    if (!/^\d{4}-\d{2}-\d{2}T/.test(attestation.verifiedAt) || !safeUrl(attestation.evidenceUrl) || !attestation.statement.trim()) throw new Error("capture attestation needs an ISO instant, HTTPS evidence URL, and statement");
    if (captureClient === "browser") {
      if (attestation.marketVerified !== true || attestation.locationVerified !== true || attestation.priceModeVerified !== true) throw new Error("browser capture attestation must affirm market, location, and price mode");
      if (!Array.isArray(attestation.screenshotSha256) || attestation.screenshotSha256.length === 0 || attestation.screenshotSha256.some((hash) => !/^[a-f0-9]{64}$/.test(hash))) throw new Error("browser capture attestation must bind screenshot SHA-256 evidence");
      if (!attestation.captureSessionHash || !/^[a-f0-9]{64}$/.test(attestation.captureSessionHash)) throw new Error("browser capture attestation must bind the capture-session manifest");
    }
  }
  if (captureSession) {
    if (captureSession.store !== store || captureSession.sourceId !== `direct-${store}-browser`) throw new Error("capture-session store/source identity does not match the requested browser capture");
    const { contentHash: declaredSessionHash, ...sessionContent } = captureSession;
    const sessionHash = await digestHex(stableJson(sessionContent));
    if (declaredSessionHash !== sessionHash) throw new Error("capture-session content hash is invalid");
    if (attestation?.captureSessionHash !== sessionHash) throw new Error("capture attestation does not bind the supplied capture-session manifest");
    const proofHashes = new Set(captureSession.canaries.flatMap((canary) => canary.screenshotSha256 ? [canary.screenshotSha256] : []));
    if (!(attestation?.screenshotSha256 ?? []).some((hash) => proofHashes.has(hash))) throw new Error("capture-session canaries do not bind the attested screenshot evidence");
    if (captureSession.canaries.length !== captureSession.chunks.length) throw new Error("every browser capture chunk requires a location/price-mode canary");
    if (Date.parse(captureSession.finishedAt) >= Date.parse(BROWSER_CAPTURE_ACCURACY_CUTOVER)) {
      if (captureSession.version !== 2) throw new Error("browser capture uses the retired pre-accuracy session contract");
      const candidates = captureSession.accuracy.discoveryRows.map(({ rowKey: _rowKey, discoveryHash: _discoveryHash, riskReasons: _riskReasons, verificationRequired: _verificationRequired, ...row }) => row);
      const recomputed = await buildBrowserCaptureAccuracy(captureSession.store, candidates, captureSession.accuracy.verifications, captureSession.terms);
      if (!recomputed.pass || stableJson(recomputed) !== stableJson(captureSession.accuracy)) throw new Error("browser capture accuracy report is incomplete, unresolved, or not reproducible");
    }
  }
  const deals = Array.isArray(document.deals) ? document.deals : [];
  if (deals.length === 0) throw new Error("regular capture document has no deals");
  const observations: ObservationInput[] = [];
  const acceptedSourceRows: Array<Record<string, unknown>> = [];
  const rejected: Array<{ index: number; reason: string }> = [];
  const buckets = new Map<string, { accepted: number; rejected: number }>();
  const sessionTerms = new Map(captureSession?.terms.map((term) => [term.termKey, term]) ?? []);
  const sessionQueries = new Map(captureSession?.terms.map((term) => [term.query, term]) ?? []);
  for (let index = 0; index < deals.length; index += 1) {
    const row = deals[index]!;
    const foundByTerm = stringValue(row.found_by_term);
    const sessionTermByQuery = foundByTerm ? sessionQueries.get(foundByTerm) : undefined;
    const bucket = sessionTermByQuery?.termKey ?? termKey(foundByTerm ?? `catalog-${Math.floor(index / 100).toString().padStart(4, "0")}`);
    const count = buckets.get(bucket) ?? { accepted: 0, rejected: 0 };
    buckets.set(bucket, count);
    const name = stringValue(row.item) ?? stringValue(row.name);
    const sizeText = stringValue(row.size_raw) ?? stringValue(row.size) ?? "";
    const parsedBasis = consumerPackageBasis(name, basis(sizeText));
    const advertisedPrice = numberValue(row.ad_price);
    const sourceCheckoutPrice = numberValue(row.current_price);
    const retailerCheckoutPrice = numberValue(row.source_checkout_price);
    const priceMultiple = numberValue(row.price_multiple);
    // Hy-Vee preserves the retailer's multi-buy total in current_price for an
    // independent source-contract check, while ad_price is the per-item shelf
    // price we intentionally publish. Normalize that explicit contract here so
    // a 2/$5 offer costs one item at $2.50, not one item at $5.00.
    const verifiedPerItemMultiBuy = advertisedPrice !== undefined
      && sourceCheckoutPrice !== undefined
      && priceMultiple !== undefined
      && Number.isInteger(priceMultiple)
      && priceMultiple > 1
      && Math.abs(sourceCheckoutPrice - advertisedPrice * priceMultiple) <= 0.02;
    const price = verifiedPerItemMultiBuy ? advertisedPrice : retailerCheckoutPrice ?? sourceCheckoutPrice ?? advertisedPrice;
    const asOf = stringValue(row.as_of) ?? stringValue(document.generated)?.slice(0, 10);
    if (!name || !parsedBasis || price === undefined || price < 0 || !asOf) {
      count.rejected += 1;
      rejected.push({ index, reason: !name ? "missing-name" : !parsedBasis ? "unparsed-size" : price === undefined ? "missing-price" : "missing-as-of" });
      continue;
    }
    let purchasePriceMinor = Math.round(price * 100);
    const regularPrice = numberValue(row.base_price) ?? numberValue(row.regular);
    const sessionTerm = captureSession ? sessionTerms.get(bucket) : undefined;
    const capturedAt = captureSession ? sessionTerm?.finishedAt : omahaDayStart(asOf.slice(0, 10));
    if (captureSession && (!foundByTerm || !sessionTerm || sessionTerm.outcome !== "success")) {
      count.rejected += 1;
      rejected.push({ index, reason: !foundByTerm ? "missing-capture-term" : !sessionTerm ? "term-outside-session" : "term-not-successful" });
      continue;
    }
    if (!capturedAt) {
      count.rejected += 1;
      rejected.push({ index, reason: "missing-capture-time" });
      continue;
    }
    const productUrl = safeUrl(row.canonical_url) ?? safeUrl(row.link_url);
    const loyaltyRequired = row.loyalty_required === true || row.member_price === true || /\b(?:loyalty|member|digital\s+coupon|with\s+card)\b/i.test(stringValue(row.price_type) ?? "");
    const membershipRequired = store === "sams" || row.membership_required === true;
    const kind: ObservationInput["kind"] = membershipRequired || loyaltyRequired ? "member" : row.marked_down === true ? "markdown" : regularPrice !== undefined && regularPrice > price ? "sale" : "everyday";
    const storeUnitPrice = store === "sams" ? verifiedUnitPrice(row.sams_unit_price)
      : store === "walmart" ? verifiedUnitPrice(row.wm_unit_price) : undefined;
    const preliminaryBasisOptions = packageBasisOptions(sizeText, name, purchasePriceMinor);
    if (storeUnitPrice && retailerCheckoutPrice === undefined
      && Math.abs(price * 1_000_000 - storeUnitPrice.perUnitMicros) <= Math.max(20_000, storeUnitPrice.perUnitMicros * 0.02)) {
      const packageQuantity = preliminaryBasisOptions
        .filter((option) => option.unit === storeUnitPrice.unit)
        .map((option) => option.quantityMicros / 1_000_000)
        .filter((quantity) => quantity > 1)
        .sort((left, right) => right - left)[0];
      if (packageQuantity) purchasePriceMinor = Math.round(storeUnitPrice.perUnitMicros * packageQuantity / 10_000);
    }
    const regularPriceMinor = regularPrice !== undefined && regularPrice >= price
      ? Math.round(regularPrice * 100 * (purchasePriceMinor / Math.max(1, Math.round(price * 100))))
      : undefined;
    const normalizedBasisQtyMicros = storeUnitPrice
      ? Math.max(1, Math.round((purchasePriceMinor * 10_000 * 1_000_000) / storeUnitPrice.perUnitMicros))
      : parsedBasis.quantityMicros;
    const identity = await productIdentity(row, index, name, sizeText, store);
    const qualifyingQuantity = verifiedPerItemMultiBuy ? Number(priceMultiple) : 1;
    const offerType: PriceSemantics["offerType"] = membershipRequired ? "member" : loyaltyRequired ? "loyalty"
      : verifiedPerItemMultiBuy ? "multibuy" : row.marked_down === true ? "markdown"
        : regularPriceMinor !== undefined && regularPriceMinor > purchasePriceMinor ? "sale" : "everyday";
    const condition: PriceSemantics["condition"] = membershipRequired
      ? (qualifyingQuantity > 1 ? "membership_quantity" : "membership")
      : loyaltyRequired ? (qualifyingQuantity > 1 ? "loyalty_quantity" : "loyalty")
        : qualifyingQuantity > 1 ? "quantity" : "none";
    const priceSemantics: PriceSemantics = {
      offerType, condition, unitPriceMinor: purchasePriceMinor, qualifyingQuantity,
      totalPriceMinor: purchasePriceMinor * qualifyingQuantity,
      ...(regularPriceMinor !== undefined ? { regularPriceMinor } : {}), ambiguity: false,
    };
    observations.push({
      externalProductKey: await externalKey(row, index), identity, name, sizeText,
      ...(productUrl ? { productUrl } : {}),
      ...(safeUrl(row.image_url) ? { imageUrl: safeUrl(row.image_url)! } : {}),
      ...(taxonomy(row, store) ? { taxonomyPath: taxonomy(row, store)! } : {}),
      package: {
        source: document.source ?? "regular-catalog",
        store,
        rawIndex: index,
        ...(verifiedPerItemMultiBuy ? { sourceCheckoutPrice, priceMultiple, priceInterpretation: "verified-per-item-multibuy" } : {}),
        ...(storeUnitPrice ? { normalizedUnitPriceSource: "sams_unit_price" } : {}),
      }, termKey: bucket, kind, currency: "USD",
      purchasePriceMinor, ...(regularPriceMinor !== undefined ? { regularPriceMinor } : {}),
      purchaseQuantity: 1, packageCount: parsedBasis.packageCount, capturedBasisUnit: parsedBasis.unit,
      capturedBasisQtyMicros: parsedBasis.quantityMicros, normalizedBasisUnit: storeUnitPrice?.unit ?? parsedBasis.unit,
      normalizedBasisQtyMicros,
      perUnitMicros: Math.round((purchasePriceMinor * 10_000 * 1_000_000) / normalizedBasisQtyMicros),
      basisOptions: packageBasisOptions(sizeText, name, purchasePriceMinor),
      loyaltyRequired, membershipRequired, rawPriceText: stringValue(row.ad_price) ?? String(price), rawSizeText: sizeText,
      capturedAt, sourcePayloadKey: `regular:${store}:${index}`, priceSemantics,
    });
    acceptedSourceRows.push(row);
    count.accepted += 1;
  }
  if (observations.length === 0) throw new Error("no regular rows could be normalized");
  let truthBoundObservations = 0;
  if (captureSession?.version === 2) {
    for (const observation of observations) {
      const match = captureSession.accuracy.discoveryRows.find((row) => row.termKey === observation.termKey
        && row.productKey === observation.externalProductKey
        && row.purchasePriceMinor === observation.purchasePriceMinor
        && normalizeName(repairCaptureMojibake(row.name)) === normalizeName(repairCaptureMojibake(observation.name)));
      if (!match) throw new Error(`normalized browser observation is not bound to exact capture truth: ${observation.termKey ?? "(no-term)"}/${observation.externalProductKey}`);
      if (Date.parse(captureSession.finishedAt) >= Date.parse(CAPTURE_SEMANTICS_CUTOVER)) {
        if (!match.truth.visible.priceSemantics || !match.truth.pageState) throw new Error("browser capture truth is missing required price semantics or page-state attestation");
        observation.priceSemantics = match.truth.visible.priceSemantics;
      }
      truthBoundObservations += 1;
    }
  }
  const captured = observations.map((item) => item.capturedAt).sort();
  const derivedTerms = [...buckets.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([key, value], ordinal) => ({
    termKey: key, ordinal, outcome: value.accepted > 0 ? "success" as const : "rejected" as const, rowCount: value.accepted,
    ...(value.rejected > 0 ? { reason: `${value.rejected} source rows rejected during normalization` } : {}),
  }));
  const terms = captureSession
    ? captureSession.terms.map((term) => ({ termKey: term.termKey, ordinal: term.ordinal, outcome: term.outcome, rowCount: term.rowCount, ...(term.reason ? { reason: term.reason } : {}) }))
    : authoredTermLedger(document) ?? derivedTerms;
  const requestedCoverage: DirectCaptureArtifact["coverageMode"] = ["full", "partial", "targeted", "ad_only"].includes(document.coverage_mode ?? "")
    ? document.coverage_mode as DirectCaptureArtifact["coverageMode"] : "partial";
  const coverageMode: DirectCaptureArtifact["coverageMode"] = captureSession?.coverageMode
    ?? (requestedCoverage === "full" && !terms.every((term) => term.outcome === "success" || term.outcome === "empty") ? "partial" : requestedCoverage);
  const priceModeVerified = attestation?.priceModeVerified === true || document.mode_verified === true || /^\d{4}-\d{2}-\d{2}/.test(stringValue(document.mode_verified) ?? "");
  const priceMode = stringValue(attestation?.priceMode) ?? stringValue(document.price_mode) ?? HEADLESS_PRICE_MODE[store];
  const sourceDescription = stringValue(document.source) ?? "";
  const headlessLocationVerified = store === "bakers"
    ? String(document.location_id ?? "") === "61500319" && /omaha\s+68106/i.test(stringValue(document.store_label) ?? "")
    : store === "family-fare"
      ? /store[_ ]id\s*6401/i.test(sourceDescription) && /omaha/i.test(sourceDescription)
      : store === "hy-vee"
        ? /store[_ ]?id\s*1465/i.test(sourceDescription) && /omaha/i.test(sourceDescription)
        : false;
  const marketVerified = attestation?.marketVerified ?? headlessLocationVerified;
  const locationVerified = attestation?.locationVerified ?? headlessLocationVerified;
  const attestationHash = attestation ? await digestHex(stableJson(attestation)) : null;
  const sourceSchema = await sourceSchemaFingerprint(acceptedSourceRows, document);
  const manifestHash = await digestHex(stableJson({ semanticContractVersion: 1, store, source: document.source, priceMode: attestation?.priceMode ?? document.price_mode, priceModeVerified, marketVerified, locationVerified, attestationHash, sourceSchema: [sourceSchema.contractFingerprint, sourceSchema.shapeFingerprint], observations: observations.map((item) => [item.externalProductKey, item.capturedAt, item.perUnitMicros, item.basisOptions ?? [], item.identity?.fingerprint ?? null, item.priceSemantics ?? null]) }));
  const capturedFrom = captureSession?.startedAt ?? captured[0]!;
  const capturedTo = captureSession?.finishedAt ?? captured.at(-1)!;
  return {
    version: 1, sourceId: `direct-${store}-${captureClient}`, coverageMode, capturedFrom, capturedTo,
    expectedTerms: captureSession?.expectedTerms ?? terms.length, marketVerified, locationVerified, priceModeVerified, priceMode,
    idempotencyKey: `regular-${store}-${capturedTo.slice(0, 10)}-${manifestHash.slice(0, 16)}`, sourceSchema, terms, observations,
    audit: { inputRows: deals.length, acceptedRows: observations.length, rejectedRows: rejected.length, rejectionReasons: Object.fromEntries([...new Set(rejected.map((item) => item.reason))].sort().map((reason) => [reason, rejected.filter((item) => item.reason === reason).length])), taxonomyRows: observations.filter((item) => item.taxonomyPath).length, stableIdentityRows: observations.filter((item) => item.identity?.confidence !== "weak").length, identityStrongRows: observations.filter((item) => item.identity?.confidence === "strong").length, promotionSemanticsRows: observations.filter((item) => item.priceSemantics).length, sourceSchema, truthBoundObservations, ...(captureSession ? { captureSession } : {}), ...(attestation ? { attestation, attestationHash } : {}) },
  };
}
