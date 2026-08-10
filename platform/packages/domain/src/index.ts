import type {
  BrowserCaptureAccuracy,
  BrowserCaptureAccuracyRow,
  BrowserCaptureStore,
  BrowserCaptureTruth,
  BrowserCaptureVerification,
  ObservationInput,
} from "@thriftycrew/contracts";

const encoder = new TextEncoder();

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

type CaptureAccuracyCandidate = Omit<BrowserCaptureAccuracyRow, "rowKey" | "discoveryHash" | "riskReasons" | "verificationRequired">;
type CaptureAccuracyTerm = { outcome: string; rowCount: number; retrieval: { targetResultCount: number; loadedResultCount: number; availableResultCount?: number | undefined; hasMoreResults: boolean; termination: string } };

function rawPriceMinor(text: string): number | undefined {
  const normalized = text.toLowerCase().replace(/,/g, "").trim();
  const multi = normalized.match(/(?:^|\s)(\d+)\s*(?:\/|for)\s*\$?([0-9]+(?:\.[0-9]{1,2})?)(?:\s|$)/);
  if (multi) return Math.round(Number(multi[2]) * 100 / Number(multi[1]));
  const price = normalized.match(/\$?([0-9]+(?:\.[0-9]{1,2})?)/);
  return price ? Math.round(Number(price[1]) * 100) : undefined;
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
  const expectedRule = dualChannel ? "next-data-price-lines" : "current-price-label";
  if (truth.parser.status !== "exact" || truth.parser.rule !== expectedRule || !sourceHostPass(store, truth.pageUrl)) return false;
  if (!expectedBrowserLocation(store, truth.location, truth.priceMode)) return false;
  if (truth.visible.priceMinor !== identity.purchasePriceMinor || rawPriceMinor(truth.visible.rawText) !== identity.purchasePriceMinor) return false;
  if (normalizeName(truth.visible.productName) !== normalizeName(identity.name)) return false;
  if (truth.visible.sizeText !== undefined && normalizeName(truth.visible.sizeText) !== normalizeName(identity.sizeText)) return false;
  if (dualChannel && !truth.structured) return false;
  if (truth.structured) {
    if (truth.structured.priceMinor !== identity.purchasePriceMinor || rawPriceMinor(truth.structured.rawText) !== identity.purchasePriceMinor) return false;
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
  };
}

function retrievalComplete(term: CaptureAccuracyTerm): boolean {
  const retrieval = term.retrieval;
  if (term.outcome === "empty") return term.rowCount === 0 && retrieval.loadedResultCount === 0 && retrieval.termination === "no-results" && !retrieval.hasMoreResults;
  if (term.outcome !== "success" || term.rowCount !== retrieval.loadedResultCount) return false;
  const required = Math.min(retrieval.targetResultCount, retrieval.availableResultCount ?? retrieval.targetResultCount);
  if (retrieval.loadedResultCount < required) return false;
  return retrieval.termination === "end-of-results" || (retrieval.termination === "target-depth" && retrieval.loadedResultCount >= retrieval.targetResultCount);
}

export async function buildBrowserCaptureAccuracy(
  store: BrowserCaptureStore,
  candidates: readonly CaptureAccuracyCandidate[],
  verifications: readonly BrowserCaptureVerification[],
  terms: readonly CaptureAccuracyTerm[],
): Promise<BrowserCaptureAccuracy> {
  const cheapest = new Set<string>();
  const byTerm = new Map<string, Array<{ index: number; price: number }>>();
  candidates.forEach((row, index) => {
    const values = byTerm.get(row.termKey) ?? [];
    values.push({ index, price: row.purchasePriceMinor });
    byTerm.set(row.termKey, values);
  });
  for (const values of byTerm.values()) cheapest.add(String(values.sort((left, right) => left.price - right.price || left.index - right.index)[0]?.index));
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
    const sample = Number.parseInt((await digestHex(rowKey)).slice(0, 4), 16) < 6554;
    const text = `${candidate.query} ${candidate.name} ${candidate.sizeText}`.toLowerCase();
    const reasons: BrowserCaptureAccuracyRow["riskReasons"] = [];
    if (cheapest.has(String(index))) reasons.push("likely-board-winner");
    if (sample) reasons.push("deterministic-sample");
    if (/\b(?:apple|avocado|banana|berry|berries|lemon|lime|orange|peach|pear|pepper|potato|tomato|lettuce|onion|produce)\b/.test(text)) reasons.push("fresh-produce");
    if (/\b(?:each|ea|ct|count|head|bunch)\b/.test(text)) reasons.push("count-priced");
    if (/\b\d+\s*(?:\/|for)\s*\$?\d+/i.test(candidate.truth.visible.rawText)) reasons.push("multibuy");
    if (candidate.purchasePriceMinor <= 10 || candidate.purchasePriceMinor >= 50_000) reasons.push("price-outlier");
    if (!candidate.taxonomyPath) reasons.push("missing-taxonomy");
    if ((duplicatePrices.get(candidate.productKey)?.size ?? 0) > 1) reasons.push("duplicate-price-conflict");
    const verificationRequired = reasons.some((reason) => reason !== "missing-taxonomy");
    if (!browserCaptureTruthPass(store, candidate, candidate.truth)) allTruthPass = false;
    rows.push({ ...candidate, rowKey, discoveryHash, riskReasons: reasons, verificationRequired });
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
    const verificationHash = await digestHex(stableJson(accuracyFingerprint({
      productKey: verification.productKey, name: verification.name, sizeText: verification.sizeText,
      purchasePriceMinor: verification.purchasePriceMinor, truth: verification.truth,
    })));
    if (verificationHash === row.discoveryHash) matchedVerificationRows += 1;
  }
  const requiredVerificationRows = rows.filter((row) => row.verificationRequired).length;
  const retrievalCompleteTerms = terms.filter(retrievalComplete).length;
  const anomalyRows = rows.filter((row) => row.riskReasons.includes("price-outlier") || row.riskReasons.includes("duplicate-price-conflict")).length;
  const relevantVerifications = verifications.filter((verification) => rowMap.has(verification.rowKey));
  return {
    policyVersion: 1,
    discoveryRows: rows,
    verifications: relevantVerifications,
    requiredVerificationRows,
    matchedVerificationRows,
    unresolvedVerificationRows: requiredVerificationRows - matchedVerificationRows,
    priceAgreementRows: rows.filter((row) => Boolean(row.truth.structured)).length,
    singleChannelRows: rows.filter((row) => !row.truth.structured).length,
    anomalyRows,
    retrievalCompleteTerms,
    pass: allTruthPass && matchedVerificationRows === requiredVerificationRows && retrievalCompleteTerms === terms.length,
  };
}

export function centsFromLegacyDollars(value: number): number {
  if (!Number.isFinite(value) || value < 0) throw new Error("legacy dollar amount must be non-negative and finite");
  return Math.round(value * 100);
}

export function microsFromLegacyPerUnit(value: number): number {
  if (!Number.isFinite(value) || value < 0) throw new Error("legacy per-unit amount must be non-negative and finite");
  return Math.round(value * 1_000_000);
}
