import type { DirectCaptureArtifact, ObservationInput } from "@thriftycrew/contracts";
import { digestHex, normalizeName, stableJson } from "@thriftycrew/domain";

type StoreKey = "aldi" | "bakers" | "family-fare" | "fareway" | "hy-vee" | "sams" | "walmart";
interface RegularDocument { store?: string; price_mode?: string; mode_verified?: boolean | string; source?: string; generated?: string; deals?: Array<Record<string, unknown>> }
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
}

const STORE_ALIASES: Record<string, StoreKey> = {
  aldi: "aldi", bakers: "bakers", "baker's": "bakers", "family-fare": "family-fare", "family fare": "family-fare",
  fareway: "fareway", hyvee: "hy-vee", "hy-vee": "hy-vee", sams: "sams", "sam's club": "sams", walmart: "walmart",
};

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function numberValue(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value !== "string") return undefined;
  const parsed = Number(value.replace(/[^0-9.-]/g, ""));
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
  const pack = normalized.match(/^(\d+)\s*[x\u00d7]\s*([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|oz|lb|ml|l|liter|g|gram|kg|ct)\b/);
  const match = pack ?? normalized.match(/([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|oz|lb|ml|l|liter|g|gram|kg|ct|dozen|gal|gallon|qt|pt|each)\b/);
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
    : rawUnit === "ct" ? "each"
    : rawUnit === "gallon" ? "gal"
    : rawUnit as ObservationInput["normalizedBasisUnit"];
  return { unit, quantityMicros: Math.max(1, Math.round(quantity * 1_000_000)), packageCount };
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
  const normalizedSize = sizeText.toLowerCase().replace(/fluid ounces?/g, "fl oz");
  const normalizedName = name.toLowerCase().replace(/fluid ounces?/g, "fl oz");
  // Package names often state container capacity ("13 gallon, 110 ct.") rather than contents.
  // Limit name-derived multiplication to mass and small-volume contents units; standalone captured
  // sizes still retain gallons/quarts/pints through basis().
  const measure = "(fl\\.?\\s*oz|ounces?|oz|pounds?|lbs?|lb|ml|liters?|liter|l|grams?|gram|g|kg)";

  for (const text of [normalizedSize, normalizedName]) {
    for (const match of text.matchAll(new RegExp(`(\\d+(?:\\.\\d+)?)\\s*(?:ct|count|pk|pack)s?\\s*(?:x|of)?\\s*(\\d+(?:\\.\\d+)?)\\s*${measure}\\b`, "g"))) {
      const unit = optionUnit(match[3]!);
      if (unit) add(unit, Number(match[1]) * Number(match[2]), "count-times-measure");
    }
    for (const match of text.matchAll(new RegExp(`(\\d+(?:\\.\\d+)?)\\s*${measure}\\s*(?:each|ea|cans?|bottles?|pouches?|cups?)?[\\s,.-]+(\\d+(?:\\.\\d+)?)\\s*(?:ct|count|pk|pack)s?\\b`, "g"))) {
      const unit = optionUnit(match[2]!);
      if (unit) add(unit, Number(match[1]) * Number(match[3]), "measure-times-count");
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

function omahaNoon(date: string): string {
  const [year, month, day] = date.split("-").map(Number);
  if (!year || !month || !day) return new Date(date).toISOString();
  const guess = Date.UTC(year, month - 1, day, 12);
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: "America/Chicago", hour12: false, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" })
    .formatToParts(new Date(guess)).reduce<Record<string, number>>((result, item) => { if (item.type !== "literal") result[item.type] = Number(item.value); return result; }, {});
  const represented = Date.UTC(parts.year!, parts.month! - 1, parts.day!, parts.hour!, parts.minute!, parts.second!);
  return new Date(guess - (represented - guess)).toISOString();
}

function termKey(value: string): string {
  return normalizeName(value).replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 150) || "catalog";
}

async function externalKey(row: Record<string, unknown>, index: number): Promise<string> {
  const direct = stringValue(row.product_id) ?? stringValue(row.item_id) ?? stringValue(row.sams_item_id) ?? stringValue(row.upc) ?? stringValue(row.sku) ?? safeUrl(row.canonical_url) ?? safeUrl(row.link_url);
  if (direct) return direct.slice(0, 300);
  const identity = {
    name: normalizeName(stringValue(row.item) ?? stringValue(row.name) ?? ""),
    size: normalizeName(stringValue(row.size_raw) ?? stringValue(row.size) ?? ""),
  };
  return `catalog-${(await digestHex(stableJson(identity))).slice(0, 32)}${identity.name ? "" : `-${index}`}`;
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

export async function buildRegularCapture(storeInput: string, document: RegularDocument, attestation?: CaptureAttestation): Promise<DirectCaptureArtifact> {
  const store = STORE_ALIASES[storeInput.toLowerCase()] ?? STORE_ALIASES[(document.store ?? "").toLowerCase()];
  if (!store) throw new Error(`unsupported store ${storeInput}`);
  if (attestation) {
    const attestedStore = STORE_ALIASES[attestation.store.toLowerCase()];
    if (attestedStore !== store) throw new Error(`capture attestation is for ${attestation.store}, not ${store}`);
    if (!/^omaha(?:,? nebraska)?$/i.test(attestation.market.trim())) throw new Error("capture attestation must verify the Omaha market");
    if (!/^\d{4}-\d{2}-\d{2}T/.test(attestation.verifiedAt) || !safeUrl(attestation.evidenceUrl) || !attestation.statement.trim()) throw new Error("capture attestation needs an ISO instant, HTTPS evidence URL, and statement");
  }
  const deals = Array.isArray(document.deals) ? document.deals : [];
  if (deals.length === 0) throw new Error("regular capture document has no deals");
  const observations: ObservationInput[] = [];
  const rejected: Array<{ index: number; reason: string }> = [];
  const buckets = new Map<string, { accepted: number; rejected: number }>();
  for (let index = 0; index < deals.length; index += 1) {
    const row = deals[index]!;
    const bucket = termKey(stringValue(row.found_by_term) ?? `catalog-${Math.floor(index / 100).toString().padStart(4, "0")}`);
    const count = buckets.get(bucket) ?? { accepted: 0, rejected: 0 };
    buckets.set(bucket, count);
    const name = stringValue(row.item) ?? stringValue(row.name);
    const sizeText = stringValue(row.size_raw) ?? stringValue(row.size) ?? "";
    const parsedBasis = basis(sizeText);
    const price = numberValue(row.current_price) ?? numberValue(row.ad_price);
    const asOf = stringValue(row.as_of) ?? stringValue(document.generated)?.slice(0, 10);
    if (!name || !parsedBasis || price === undefined || price < 0 || !asOf) {
      count.rejected += 1;
      rejected.push({ index, reason: !name ? "missing-name" : !parsedBasis ? "unparsed-size" : price === undefined ? "missing-price" : "missing-as-of" });
      continue;
    }
    const purchasePriceMinor = Math.round(price * 100);
    const regularPrice = numberValue(row.base_price) ?? numberValue(row.regular);
    const capturedAt = omahaNoon(asOf.slice(0, 10));
    const productUrl = safeUrl(row.canonical_url) ?? safeUrl(row.link_url);
    const kind: ObservationInput["kind"] = row.marked_down === true ? "markdown" : regularPrice !== undefined && regularPrice > price ? "sale" : "everyday";
    const storeUnitPrice = store === "sams" ? verifiedUnitPrice(row.sams_unit_price) : undefined;
    const normalizedBasisQtyMicros = storeUnitPrice
      ? Math.max(1, Math.round((purchasePriceMinor * 10_000 * 1_000_000) / storeUnitPrice.perUnitMicros))
      : parsedBasis.quantityMicros;
    observations.push({
      externalProductKey: await externalKey(row, index), name, sizeText,
      ...(productUrl ? { productUrl } : {}),
      ...(taxonomy(row, store) ? { taxonomyPath: taxonomy(row, store)! } : {}),
      package: {
        source: document.source ?? "regular-catalog",
        store,
        rawIndex: index,
        ...(storeUnitPrice ? { normalizedUnitPriceSource: "sams_unit_price" } : {}),
      }, termKey: bucket, kind, currency: "USD",
      purchasePriceMinor, ...(regularPrice !== undefined && regularPrice >= price ? { regularPriceMinor: Math.round(regularPrice * 100) } : {}),
      purchaseQuantity: 1, packageCount: parsedBasis.packageCount, capturedBasisUnit: parsedBasis.unit,
      capturedBasisQtyMicros: parsedBasis.quantityMicros, normalizedBasisUnit: storeUnitPrice?.unit ?? parsedBasis.unit,
      normalizedBasisQtyMicros,
      perUnitMicros: Math.round((purchasePriceMinor * 10_000 * 1_000_000) / normalizedBasisQtyMicros),
      basisOptions: packageBasisOptions(sizeText, name, purchasePriceMinor),
      loyaltyRequired: false, membershipRequired: store === "sams", rawPriceText: stringValue(row.ad_price) ?? String(price), rawSizeText: sizeText,
      capturedAt, sourcePayloadKey: `regular:${store}:${index}`,
    });
    count.accepted += 1;
  }
  if (observations.length === 0) throw new Error("no regular rows could be normalized");
  const captured = observations.map((item) => item.capturedAt).sort();
  const terms = [...buckets.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([key, value], ordinal) => ({
    termKey: key, ordinal, outcome: value.accepted > 0 ? "success" as const : "rejected" as const, rowCount: value.accepted,
    ...(value.rejected > 0 ? { reason: `${value.rejected} source rows rejected during normalization` } : {}),
  }));
  const priceModeVerified = attestation?.priceModeVerified === true || document.mode_verified === true || /^\d{4}-\d{2}-\d{2}/.test(stringValue(document.mode_verified) ?? "");
  const marketVerified = attestation?.marketVerified ?? true;
  const locationVerified = attestation?.locationVerified ?? true;
  const attestationHash = attestation ? await digestHex(stableJson(attestation)) : null;
  const manifestHash = await digestHex(stableJson({ store, source: document.source, priceMode: attestation?.priceMode ?? document.price_mode, priceModeVerified, marketVerified, locationVerified, attestationHash, observations: observations.map((item) => [item.externalProductKey, item.capturedAt, item.perUnitMicros, item.basisOptions ?? []]) }));
  return {
    version: 1, sourceId: `direct-${store}-headless`, coverageMode: "partial", capturedFrom: captured[0]!, capturedTo: captured.at(-1)!,
    expectedTerms: terms.length, marketVerified, locationVerified, priceModeVerified,
    idempotencyKey: `regular-${store}-${captured.at(-1)!.slice(0, 10)}-${manifestHash.slice(0, 16)}`, terms, observations,
    audit: { inputRows: deals.length, acceptedRows: observations.length, rejectedRows: rejected.length, rejectionReasons: Object.fromEntries([...new Set(rejected.map((item) => item.reason))].sort().map((reason) => [reason, rejected.filter((item) => item.reason === reason).length])), taxonomyRows: observations.filter((item) => item.taxonomyPath).length, ...(attestation ? { attestation, attestationHash } : {}) },
  };
}
