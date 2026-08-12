import { readFileSync } from "node:fs";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";
import {
  browserCaptureCanarySchema,
  browserCaptureRetrievalSchema,
  browserCaptureSessionSchema,
  browserCaptureTruthSchema,
  browserCaptureVerificationSchema,
  type BrowserCaptureSessionV2,
  type BrowserCaptureStore,
  type BrowserCaptureVerification,
} from "@thriftycrew/contracts";
import { browserCaptureTruthPass, buildBrowserCaptureAccuracy, digestHex, normalizeName, parseCapturePriceText, stableJson } from "@thriftycrew/domain";
import { compileProductMatcher } from "@thriftycrew/engine";
import { captureAdapterManifest, validateCaptureAdapterManifest, type CaptureAdapterManifest } from "../../../scripts/browser-capture-adapters/adapter-registry.mjs";
import { commitSessionChunk, completeSessionWorkUnits, readCatalogQueryStats, readPlannerJournal, readSessionJournal, readSessionPayload, replaceCatalogSnapshot, replacePlannerJournal, replaceSessionWorkUnits, sessionEvidence, setCaptureSessionPhase, storeSessionEvidence, upsertSessionJournal } from "./capture-journal";

const storeSchema = z.enum(["aldi", "fareway", "sams", "walmart"]);
type BrowserStore = z.infer<typeof storeSchema>;

const termOutcomeSchema = z.enum(["success", "empty", "rejected", "blocked"]);
const discoveryChunkSchema = z.object({
  version: z.literal(2),
  phase: z.literal("discovery"),
  store: storeSchema,
  canary: browserCaptureCanarySchema.omit({ ordinal: true }),
  terms: z.array(z.object({
    query: z.string().trim().min(1).max(500),
    outcome: termOutcomeSchema,
    rowCount: z.number().int().nonnegative(),
    attempts: z.number().int().positive().max(20),
    startedAt: z.iso.datetime({ offset: true }),
    finishedAt: z.iso.datetime({ offset: true }),
    retrieval: browserCaptureRetrievalSchema,
    reason: z.string().trim().min(1).max(1000).optional(),
  })).min(1).max(20),
  rows: z.array(z.record(z.string(), z.unknown())).max(10_000),
});

const verificationChunkSchema = z.object({
  version: z.literal(2),
  phase: z.literal("verification"),
  store: storeSchema,
  canary: browserCaptureCanarySchema.omit({ ordinal: true }),
  verifications: z.array(browserCaptureVerificationSchema).min(1).max(200),
});

const chunkSchema = z.discriminatedUnion("phase", [discoveryChunkSchema, verificationChunkSchema]);
type CaptureChunk = z.infer<typeof chunkSchema>;
type DiscoveryChunk = z.infer<typeof discoveryChunkSchema>;

interface DraftSession {
  version: 2;
  sessionId: string;
  store: BrowserStore;
  sourceId: string;
  worklist: Array<{ termKey: string; query: string; ordinal: number }>;
  worklistHash: string;
  startedAt: string;
  adapter?: CaptureAdapterManifest;
  chunks: Array<{ id: string; file: string; sha256: string; createdAt: string }>;
  plannerHistoryFile?: string;
  plannerHistoryNamespace?: string;
}

const STORE_COLUMNS: Record<BrowserStore, string[]> = {
  walmart: ["q", "n", "lp", "up", "id", "size", "taxonomy_path", "url", "image_url"],
  sams: ["q", "n", "lp", "up", "id", "size", "taxonomy_path", "url", "image_url"],
  aldi: ["id", "term", "name", "prices", "unit", "size", "href", "taxonomy_path"],
  fareway: ["id", "term", "name", "price", "per", "orig", "unit", "size", "url", "taxonomy_path"],
};

const TERM_COLUMN: Record<BrowserStore, "q" | "term"> = { walmart: "q", sams: "q", aldi: "term", fareway: "term" };
const SOURCE_IDS: Record<BrowserStore, string> = {
  aldi: "direct-aldi-browser",
  fareway: "direct-fareway-browser",
  sams: "direct-sams-browser",
  walmart: "direct-walmart-browser",
};

const CAPTURE_COMMODITIES = JSON.parse(readFileSync(new URL("../../../config/commodities.json", import.meta.url), "utf8")) as Array<{
  id: string; include?: string[]; exclude?: string[]; priority?: number;
}>;
const CAPTURE_COMMODITY_IDS = new Set(CAPTURE_COMMODITIES.map((commodity) => commodity.id));
const CAPTURE_PRODUCT_MATCHER = compileProductMatcher(CAPTURE_COMMODITIES.map((commodity) => ({
  commodityId: commodity.id,
  includes: commodity.include ?? [],
  excludes: commodity.exclude ?? [],
  priority: commodity.priority ?? 0,
})));

function termKey(query: string): string {
  return normalizeName(query).replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 150) || "term";
}

function normalizedString(value: unknown): string {
  return typeof value === "string" ? value.trim() : value === undefined || value === null ? "" : String(value).trim();
}

function validateCanary(store: BrowserStore, canary: DiscoveryChunk["canary"]): void {
  if (!/^omaha(?:,?\s*(?:ne|nebraska))?$/i.test(canary.market.trim())) throw new Error("capture canary must verify the Omaha market");
  const location = canary.location.toLowerCase();
  const mode = canary.priceMode.toLowerCase();
  const locationPass = store === "walmart" ? /omaha l st|12850 l st|12812 s 38th/.test(location)
    : store === "sams" ? /omaha|13130 l st/.test(location)
    : store === "aldi" ? /ola 42|omaha/.test(location)
    : /17070 audrey|omaha/.test(location);
  const modePass = store === "sams" ? /pickup|club/.test(mode)
    : store === "walmart" ? /pickup/.test(mode)
    : /in[- ]?store/.test(mode);
  if (!locationPass) throw new Error(`${store} canary does not prove the required Omaha location`);
  if (!modePass) throw new Error(`${store} canary does not prove the required price mode`);
}

function projectedIdentity(store: BrowserStore, row: Record<string, unknown>): { query: string; productKey: string; name: string; sizeText: string; taxonomyPath?: string; purchasePriceMinor: number } {
  const query = normalizedString(row[TERM_COLUMN[store]]);
  const name = normalizedString(row[store === "walmart" || store === "sams" ? "n" : "name"]);
  const productKey = normalizedString(row[store === "aldi" ? "href" : store === "fareway" ? "url" : "id"]);
  const rawPrice = normalizedString(row[store === "aldi" ? "prices" : store === "fareway" ? "price" : "lp"]);
  const parsedPrice = parseCapturePriceText(rawPrice);
  if (!parsedPrice) throw new Error(`${store} projected row price is not an exact unambiguous price: ${rawPrice || "(missing)"}`);
  const purchasePriceMinor = parsedPrice.unitPriceMinor;
  if (!Number.isSafeInteger(purchasePriceMinor)) throw new Error(`${store} projected row price is outside the supported range`);
  const sizeText = normalizedString(row.size);
  const taxonomyPath = normalizedString(row.taxonomy_path) || undefined;
  return { query, productKey, name, sizeText, ...(taxonomyPath ? { taxonomyPath } : {}), purchasePriceMinor };
}

function validateRows(store: BrowserStore, chunk: DiscoveryChunk, worklist: Map<string, string>): void {
  const counts = new Map<string, number>();
  for (const row of chunk.rows) {
    const unexpected = Object.keys(row).filter((column) => column !== "_capture" && !STORE_COLUMNS[store].includes(column));
    if (unexpected.length) throw new Error(`${store} projected row contains non-allowlisted fields: ${unexpected.join(", ")}`);
    const identity = projectedIdentity(store, row);
    const query = identity.query;
    if (!worklist.has(query)) throw new Error(`row refers to query outside the worklist: ${query || "(missing)"}`);
    counts.set(query, (counts.get(query) ?? 0) + 1);
    if (!identity.name || !identity.productKey) throw new Error(`${store} projected row must retain term, name, product identity, and price`);
    const truth = browserCaptureTruthSchema.parse(row._capture);
    if (!browserCaptureTruthPass(store as BrowserCaptureStore, identity, truth)) {
      throw new Error(`${store} projected row visible/structured price, product identity, parser, location, or price-mode evidence disagrees with the accepted row`);
    }
    if (normalizeName(truth.location) !== normalizeName(chunk.canary.location) || normalizeName(truth.priceMode) !== normalizeName(chunk.canary.priceMode)) {
      throw new Error(`${store} projected row location/price-mode truth disagrees with its chunk canary`);
    }
    const termInterval = chunk.terms.find((term) => term.query === query)!;
    if (truth.capturedAt < termInterval.startedAt || truth.capturedAt > termInterval.finishedAt) throw new Error(`${store} projected row capture instant is outside its term interval`);
  }
  for (const term of chunk.terms) {
    const count = counts.get(term.query) ?? 0;
    if (count !== term.rowCount) throw new Error(`term ${term.query} declares ${term.rowCount} rows but the chunk contains ${count}`);
    if (term.outcome === "success" && count === 0) throw new Error(`successful term ${term.query} must contain at least one row`);
    if (term.outcome !== "success" && count !== 0) throw new Error(`${term.outcome} term ${term.query} cannot contain rows`);
    if ((term.outcome === "blocked" || term.outcome === "rejected") && !term.reason) throw new Error(`${term.outcome} term ${term.query} requires a reason`);
    if (term.outcome === "success" && term.retrieval.loadedResultCount !== count) throw new Error(`term ${term.query} loaded ${term.retrieval.loadedResultCount} results but retained ${count}`);
    if (term.outcome === "empty" && term.retrieval.termination !== "no-results") throw new Error(`empty term ${term.query} must prove no-results pagination termination`);
    if ((term.outcome === "blocked" || term.outcome === "rejected") && !["blocked", "error"].includes(term.retrieval.termination)) throw new Error(`${term.outcome} term ${term.query} must retain blocked/error retrieval state`);
  }
}

async function atomicJson(file: string, value: unknown, pretty = true): Promise<void> {
  const temporary = `${file}.tmp-${crypto.randomUUID()}`;
  await writeFile(temporary, `${JSON.stringify(value, null, pretty ? 2 : undefined)}\n`, "utf8");
  await rename(temporary, file);
}

async function loadDraft(directory: string): Promise<DraftSession> {
  let draft = readSessionJournal<DraftSession>(directory);
  if (!draft) {
    draft = JSON.parse((await readFile(path.join(directory, "session.json"), "utf8")).replace(/^\uFEFF/, "")) as DraftSession;
    upsertSessionJournal(directory, draft);
  }
  if (draft.version !== 2 || !draft.sessionId || !Array.isArray(draft.worklist) || !Array.isArray(draft.chunks)) throw new Error(`invalid browser capture session in ${directory}`);
  return draft;
}

async function persistDraft(directory: string, draft: DraftSession): Promise<void> {
  // SQLite/WAL is the concurrency and recovery authority. The JSON mirror remains
  // a portable recovery artifact and keeps pre-controller sessions readable.
  upsertSessionJournal(directory, draft);
  await atomicJson(path.join(directory, "session.json"), draft);
}

function parseWorklist(source: string): string[] {
  const trimmed = source.trim();
  if (!trimmed) return [];
  if (trimmed.startsWith("[") || trimmed.startsWith("{")) {
    const parsed = JSON.parse(trimmed) as unknown;
    const values = Array.isArray(parsed) ? parsed : Array.isArray((parsed as { terms?: unknown[] }).terms) ? (parsed as { terms: unknown[] }).terms : [];
    return values.map((value) => typeof value === "string" ? value : normalizedString((value as Record<string, unknown>).query ?? (value as Record<string, unknown>).term)).filter(Boolean);
  }
  return source.split(/\r?\n/).map((line) => line.trim()).filter((line) => line && !line.startsWith("#"));
}

function uniqueInOrder(values: readonly string[]): string[] {
  const seen = new Set<string>();
  return values.filter((value) => {
    const normalized = value.trim();
    if (!normalized || seen.has(normalized)) return false;
    seen.add(normalized);
    return true;
  }).map((value) => value.trim());
}

function queryIdentity(value: string): string {
  return normalizeName(value).replace(/[^a-z0-9]+/g, " ").trim();
}

function mergeEquivalentQueries(values: readonly string[]): { terms: string[]; aliases: Array<{ retained: string; merged: string }> } {
  const canonical = new Map<string, string>();
  const terms: string[] = [];
  const aliases: Array<{ retained: string; merged: string }> = [];
  for (const value of values.map((item) => item.trim()).filter(Boolean)) {
    const identity = queryIdentity(value);
    const retained = canonical.get(identity);
    if (retained) {
      if (retained !== value) aliases.push({ retained, merged: value });
      continue;
    }
    canonical.set(identity, value);
    terms.push(value);
  }
  return { terms, aliases };
}

function pullOrderQueries(source: string): string[] {
  return uniqueInOrder(source.split(/\r?\n/).flatMap((line) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) return [];
    const columns = line.split("\t").map((value) => value.trim());
    if (columns.length < 2 || !columns[0] || !columns[1]) throw new Error(`invalid generated pull-order row: ${trimmed}`);
    return [columns[1]];
  }));
}

function rescueQueries(source: string): string[] {
  return uniqueInOrder(source.split(/\r?\n/).flatMap((line) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) return [];
    const columns = line.split("\t").map((value) => value.trim());
    if (columns.length < 2 || !columns[0] || !columns[1]) throw new Error(`invalid rescue worklist row: ${trimmed}`);
    return [columns[0]];
  }));
}

export async function buildCaptureSessionWorklist(
  pullOrderFile: string,
  rescueFile: string | null,
  outputFile: string,
): Promise<Record<string, unknown>> {
  const pullOrder = pullOrderQueries(await readFile(pullOrderFile, "utf8"));
  if (pullOrder.length === 0) throw new Error("generated pull order contains no search queries");
  const rescue = rescueFile ? rescueQueries(await readFile(rescueFile, "utf8")) : [];
  const merged = mergeEquivalentQueries([...rescue, ...pullOrder]);
  const rescueIdentities = new Set(rescue.map(queryIdentity));
  // Rescue stays first. Within each lane, prefer queries that historically produce
  // distinct products quickly; no query is removed except a proven normalized duplicate.
  let history: Record<string, { distinctProducts?: number; duplicateProducts?: number; durationMs?: number; complete?: boolean }> = {};
  const historyFile = path.join(path.dirname(pullOrderFile), `${path.basename(pullOrderFile, path.extname(pullOrderFile))}-query-history.json`);
  const historyNamespace = path.resolve(pullOrderFile).toLowerCase();
  history = readPlannerJournal(historyNamespace) as typeof history;
  if (Object.keys(history).length === 0) {
    try {
      history = JSON.parse(await readFile(historyFile, "utf8")) as typeof history;
      replacePlannerJournal(historyNamespace, history as Record<string, Record<string, unknown>>, new Date().toISOString());
    } catch { /* first cycle has no history */ }
  }
  const inferredStore = (["aldi", "fareway", "sams", "walmart"] as const).find((store) => path.basename(pullOrderFile).toLowerCase().includes(store));
  const catalog = inferredStore ? readCatalogQueryStats(inferredStore) : {};
  const score = (query: string): number => {
    const row = history[queryIdentity(query)];
    if (!row) return 0;
    const yieldScore = Math.max(0, row.distinctProducts ?? 0) * 1000;
    const duplicatePenalty = Math.max(0, row.duplicateProducts ?? 0) * 100;
    const latencyPenalty = Math.max(0, row.durationMs ?? 0) / 1000;
    const catalogRow = catalog[queryIdentity(query)];
    const reusableCatalogScore = Math.max(0, catalogRow?.productCount ?? 0) * 250;
    const staleRefreshScore = Math.min(14, Math.max(0, catalogRow?.ageDays ?? 0)) * 25;
    return yieldScore + reusableCatalogScore + staleRefreshScore - duplicatePenalty - latencyPenalty + (row.complete === true ? 100 : 0);
  };
  const terms = merged.terms
    .map((query, ordinal) => ({ query, ordinal, rescue: rescueIdentities.has(queryIdentity(query)), score: score(query) }))
    .sort((left, right) => Number(right.rescue) - Number(left.rescue) || right.score - left.score || left.ordinal - right.ordinal)
    .map((entry) => entry.query);
  const pullSet = new Set(pullOrder);
  const termIdentities = new Set(terms.map(queryIdentity));
  const retainedPullTerms = pullOrder.filter((term) => termIdentities.has(queryIdentity(term))).length;
  if (retainedPullTerms !== pullOrder.length) throw new Error(`capture worklist lost ${pullOrder.length - retainedPullTerms} generated pull-order queries`);
  await atomicJson(outputFile, { version: 2, terms, aliases: merged.aliases, planner: { historyFile, historyNamespace, historyQueries: Object.keys(history).length, catalogQueries: Object.keys(catalog).length, shadowCoverageTerms: pullOrder.length } });
  return {
    ok: true,
    outputFile,
    pullOrderTerms: pullOrder.length,
    rescueTerms: rescue.length,
    rescueTermsInPullOrder: rescue.filter((term) => pullSet.has(term)).length,
    rescueOnlyTerms: rescue.filter((term) => !pullSet.has(term)).length,
    mergedDuplicateTerms: merged.aliases.length,
    historyQueries: Object.keys(history).length,
    catalogQueries: Object.keys(catalog).length,
    totalTerms: terms.length,
  };
}

export function rollingDiscoveryTarget(totalTerms: number, instant = new Date()): { day: string; shard: number; shards: number; cumulativeTarget: number; remainingAfterTarget: number } {
  if (!Number.isSafeInteger(totalTerms) || totalTerms <= 0) throw new Error("rolling discovery requires a positive term count");
  const weekday = new Intl.DateTimeFormat("en-US", { timeZone: "America/Chicago", weekday: "short" }).format(instant);
  const shard = ({ Wed: 1, Thu: 2, Fri: 3, Sat: 4 } as Record<string, number>)[weekday];
  if (!shard) throw new Error(`rolling browser discovery is only scheduled Wednesday-Saturday (received ${weekday})`);
  const cumulativeTarget = Math.ceil(totalTerms * shard / 4);
  return { day: weekday, shard, shards: 4, cumulativeTarget, remainingAfterTarget: totalTerms - cumulativeTarget };
}

export async function initializeCaptureSession(storeInput: string, worklistFile: string, directory: string, startedAt = new Date().toISOString()): Promise<DraftSession> {
  const store = storeSchema.parse(storeInput);
  z.iso.datetime({ offset: true }).parse(startedAt);
  const worklistSource = await readFile(worklistFile, "utf8");
  const terms = [...new Set(parseWorklist(worklistSource))];
  if (terms.length === 0 || terms.length > 2000) throw new Error("browser capture worklist must contain 1-2000 terms");
  const usedKeys = new Set<string>();
  const keyed = terms.map((query, ordinal) => {
    const base = termKey(query);
    let key = base;
    if (usedKeys.has(key)) key = `${base.slice(0, 140)}-${ordinal}`;
    while (usedKeys.has(key)) key = `${base.slice(0, 135)}-${ordinal}-${usedKeys.size}`;
    usedKeys.add(key);
    return { termKey: key, query, ordinal };
  });
  const worklistHash = await digestHex(stableJson(terms));
  const sessionId = `browser-${store}-${startedAt.slice(0, 10)}-${worklistHash.slice(0, 12)}`;
  let plannerHistoryFile: string | undefined;
  let plannerHistoryNamespace: string | undefined;
  try {
    const document = JSON.parse(worklistSource) as { planner?: { historyFile?: unknown; historyNamespace?: unknown } };
    if (typeof document.planner?.historyFile === "string") plannerHistoryFile = path.resolve(document.planner.historyFile);
    if (typeof document.planner?.historyNamespace === "string") plannerHistoryNamespace = document.planner.historyNamespace;
  } catch { /* plain-text worklists have no planner history */ }
  const adapter = validateCaptureAdapterManifest(await captureAdapterManifest(store));
  const draft: DraftSession = { version: 2, sessionId, store, sourceId: SOURCE_IDS[store], worklist: keyed, worklistHash, startedAt, adapter, chunks: [], ...(plannerHistoryFile ? { plannerHistoryFile } : {}), ...(plannerHistoryNamespace ? { plannerHistoryNamespace } : {}) };
  await mkdir(path.join(directory, "chunks"), { recursive: true });
  try {
    const existing = await loadDraft(directory);
    if (existing.store !== draft.store || existing.sourceId !== draft.sourceId || existing.worklistHash !== draft.worklistHash) throw new Error(`capture session directory already belongs to ${existing.sessionId}`);
    replaceSessionWorkUnits(directory, store, "discovery", existing.worklist.map((term) => ({
      key: term.query, ordinal: term.ordinal, priority: existing.worklist.length - term.ordinal,
      payload: { termKey: term.termKey, query: term.query, ...(existing.adapter ? { adapter: { id: existing.adapter.id, version: existing.adapter.version, sha256: existing.adapter.sha256 } } : {}) },
    })), existing.startedAt);
    const existingState = await loadSessionState(directory, existing);
    completeSessionWorkUnits(directory, "discovery", [...existingState.latest.keys()]);
    return existing;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  await persistDraft(directory, draft);
  replaceSessionWorkUnits(directory, store, "discovery", keyed.map((term) => ({
    key: term.query,
    ordinal: term.ordinal,
    priority: keyed.length - term.ordinal,
    payload: { termKey: term.termKey, query: term.query, adapter: { id: adapter.id, version: adapter.version, sha256: adapter.sha256 } },
  })), startedAt);
  return draft;
}

export async function appendCaptureChunk(directory: string, chunkFile: string): Promise<{ id: string; idempotent: boolean; terms: number; rows: number }> {
  const draft = await loadDraft(directory);
  const bytes = new Uint8Array(await readFile(chunkFile));
  const chunk = chunkSchema.parse(JSON.parse(new TextDecoder().decode(bytes).replace(/^\uFEFF/, "")));
  if (chunk.store !== draft.store) throw new Error(`chunk is for ${chunk.store}, not ${draft.store}`);
  validateCanary(draft.store, chunk.canary);
  const worklist = new Map(draft.worklist.map((term) => [term.query, term.termKey]));
  if (chunk.phase === "discovery") {
    if (new Set(chunk.terms.map((term) => term.query)).size !== chunk.terms.length) throw new Error("chunk contains duplicate term results");
    for (const term of chunk.terms) if (!worklist.has(term.query)) throw new Error(`chunk term is outside the worklist: ${term.query}`);
    validateRows(draft.store, chunk, worklist);
  } else {
    if (new Set(chunk.verifications.map((item) => item.rowKey)).size !== chunk.verifications.length) throw new Error("verification chunk contains duplicate row keys");
    for (const verification of chunk.verifications) {
      if (verification.outcome === "observed" && verification.truth && !browserCaptureTruthPass(draft.store, {
        productKey: verification.productKey!, name: verification.name!, sizeText: verification.sizeText!, purchasePriceMinor: verification.purchasePriceMinor!,
      }, verification.truth)) throw new Error(`verification ${verification.rowKey} contains internally disagreeing product or price evidence`);
      if (verification.truth && (normalizeName(verification.truth.location) !== normalizeName(chunk.canary.location) || normalizeName(verification.truth.priceMode) !== normalizeName(chunk.canary.priceMode))) {
        throw new Error(`verification ${verification.rowKey} location/price-mode truth disagrees with its chunk canary`);
      }
      if (verification.truth && verification.truth.capturedAt !== verification.observedAt) throw new Error(`verification ${verification.rowKey} truth timestamp does not match observedAt`);
    }
  }
  const sha256 = await digestHex(bytes);
  const id = `chunk-${sha256.slice(0, 24)}`;
  const existing = draft.chunks.find((entry) => entry.id === id);
  if (existing) return { id, idempotent: true, terms: chunk.phase === "discovery" ? chunk.terms.length : 0, rows: chunk.phase === "discovery" ? chunk.rows.length : chunk.verifications.length };
  const stored = `${String(draft.chunks.length).padStart(4, "0")}-${id}.json`;
  const entry = { id, file: stored, sha256, createdAt: new Date().toISOString() };
  draft.chunks.push(entry);
  // The SQLite transaction is the commit point: chunk bytes, session progress,
  // and coordinator work completion become durable together. Disk JSON is only
  // a portable mirror and can always be rebuilt from the journal.
  commitSessionChunk(directory, draft, entry, bytes);
  await mkdir(path.join(directory, "chunks"), { recursive: true });
  await writeFile(path.join(directory, "chunks", stored), bytes);
  await atomicJson(path.join(directory, "session.json"), draft);
  return { id, idempotent: false, terms: chunk.phase === "discovery" ? chunk.terms.length : 0, rows: chunk.phase === "discovery" ? chunk.rows.length : chunk.verifications.length };
}

function csvValue(value: unknown): string {
  const text = normalizedString(value);
  return /["|\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

async function renderProjectedCapture(
  store: BrowserStore,
  rows: Array<Record<string, unknown>>,
  outputFile: string,
  worklist: DraftSession["worklist"],
): Promise<string> {
  const termKeyByQuery = new Map(worklist.map((term) => [term.query, term.termKey]));
  let output: string;
  if (store === "fareway") {
    const grouped = new Map<string, { id: string; term: string; candidates: Array<Record<string, unknown>> }>();
    for (const row of rows) {
      const term = normalizedString(row.term);
      const id = termKeyByQuery.get(term);
      if (!id) throw new Error(`fareway projected row refers to a query outside the finalized worklist: ${term || "(missing)"}`);
      const group = grouped.get(id) ?? { id, term, candidates: [] };
      group.candidates.push(Object.fromEntries(STORE_COLUMNS.fareway.filter((column) => column !== "id" && column !== "term").map((column) => [column, normalizedString(row[column])])));
      grouped.set(id, group);
    }
    output = [...grouped.values()].map((group) => JSON.stringify(group)).join("\n") + "\n";
  }
  else {
    const columns = STORE_COLUMNS[store];
    output = `${columns.join("|")}\n${rows.map((row) => columns.map((column) => {
      if (store !== "aldi" || column !== "id") return csvValue(row[column]);
      const query = normalizedString(row.term);
      const id = termKeyByQuery.get(query);
      if (!id) throw new Error(`aldi projected row refers to a query outside the finalized worklist: ${query || "(missing)"}`);
      return csvValue(id);
    }).join("|")).join("\n")}\n`;
  }
  const temporary = `${outputFile}.tmp-${crypto.randomUUID()}`;
  await mkdir(path.dirname(outputFile), { recursive: true });
  await writeFile(temporary, output, "utf8");
  await rename(temporary, outputFile);
  return digestHex(new TextEncoder().encode(output));
}

interface LoadedSessionState {
  latest: Map<string, { result: DiscoveryChunk["terms"][number]; rows: Array<Record<string, unknown>> }>;
  canaries: BrowserCaptureSessionV2["canaries"];
  chunkEntries: BrowserCaptureSessionV2["chunks"];
  verifications: BrowserCaptureVerification[];
}

async function loadSessionState(directory: string, draft: DraftSession): Promise<LoadedSessionState> {
  const latest: LoadedSessionState["latest"] = new Map();
  const canaries: BrowserCaptureSessionV2["canaries"] = [];
  const chunkEntries: BrowserCaptureSessionV2["chunks"] = [];
  const verifications: BrowserCaptureVerification[] = [];
  for (let ordinal = 0; ordinal < draft.chunks.length; ordinal += 1) {
    const entry = draft.chunks[ordinal]!;
    let bytes: Uint8Array;
    try { bytes = new Uint8Array(await readFile(path.join(directory, "chunks", entry.file))); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      const payload = readSessionPayload(directory, entry.id);
      if (!payload) throw error;
      bytes = payload.body;
      await mkdir(path.join(directory, "chunks"), { recursive: true });
      await writeFile(path.join(directory, "chunks", entry.file), bytes);
    }
    if (await digestHex(bytes) !== entry.sha256) throw new Error(`capture chunk hash mismatch: ${entry.file}`);
    const chunk = chunkSchema.parse(JSON.parse(new TextDecoder().decode(bytes).replace(/^\uFEFF/, "")));
    canaries.push({ ...chunk.canary, ordinal });
    if (chunk.phase === "discovery") {
      const termColumn = TERM_COLUMN[draft.store];
      for (const result of chunk.terms) latest.set(result.query, { result, rows: chunk.rows.filter((row) => normalizedString(row[termColumn]) === result.query) });
      chunkEntries.push({ id: entry.id, phase: chunk.phase, ordinal, termKeys: chunk.terms.map((term) => draft.worklist.find((item) => item.query === term.query)!.termKey), rowCount: chunk.rows.length, verificationCount: 0, sha256: entry.sha256, createdAt: entry.createdAt });
    } else {
      verifications.push(...chunk.verifications);
      chunkEntries.push({ id: entry.id, phase: chunk.phase, ordinal, termKeys: [], rowCount: 0, verificationCount: chunk.verifications.length, sha256: entry.sha256, createdAt: entry.createdAt });
    }
  }
  return { latest, canaries, chunkEntries, verifications };
}

function finalizedTerms(draft: DraftSession, latest: LoadedSessionState["latest"]): BrowserCaptureSessionV2["terms"] {
  return draft.worklist.map((term) => {
    const captured = latest.get(term.query)?.result;
    return captured ? {
      termKey: term.termKey, query: term.query, ordinal: term.ordinal, outcome: captured.outcome, rowCount: captured.rowCount,
      attempts: captured.attempts, startedAt: captured.startedAt, finishedAt: captured.finishedAt, retrieval: captured.retrieval,
      ...(captured.reason ? { reason: captured.reason } : {}),
    } : {
      termKey: term.termKey, query: term.query, ordinal: term.ordinal, outcome: "not_attempted" as const, rowCount: 0, attempts: 0,
      startedAt: draft.startedAt, finishedAt: draft.startedAt, reason: "term was not attempted before finalization",
      retrieval: { targetResultCount: 1, loadedResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "error" as const },
    };
  });
}

function accuracyCandidates(draft: DraftSession, state: LoadedSessionState): Array<Parameters<typeof buildBrowserCaptureAccuracy>[1][number]> {
  return draft.worklist.flatMap((term) => (state.latest.get(term.query)?.rows ?? []).map((row) => {
    const identity = projectedIdentity(draft.store, row);
    const match = CAPTURE_COMMODITY_IDS.has(term.termKey) ? CAPTURE_PRODUCT_MATCHER(identity.name) : undefined;
    return {
      termKey: term.termKey,
      query: term.query,
      productKey: identity.productKey,
      name: identity.name,
      sizeText: identity.sizeText,
      ...(identity.taxonomyPath ? { taxonomyPath: identity.taxonomyPath } : {}),
      ...(match ? { matchEligible: match.status === "matched" && match.commodityId === term.termKey } : {}),
      purchasePriceMinor: identity.purchasePriceMinor,
      truth: browserCaptureTruthSchema.parse(row._capture),
    };
  }));
}

async function buildProductEvidence(
  accuracy: Awaited<ReturnType<typeof buildBrowserCaptureAccuracy>>,
  chunks: BrowserCaptureSessionV2["chunks"],
  retainedRows: number,
): Promise<NonNullable<BrowserCaptureSessionV2["productEvidence"]>> {
  type ProductEvidence = NonNullable<BrowserCaptureSessionV2["productEvidence"]>;
  const snapshots = new Map<string, ProductEvidence["productSnapshots"][number]>();
  const snapshotByRow = new Map<string, string>();
  for (const row of accuracy.discoveryRows) {
    const semanticHash = await digestHex(stableJson({ productKey: row.productKey, name: row.name, sizeText: row.sizeText, taxonomyPath: row.taxonomyPath ?? null, purchasePriceMinor: row.purchasePriceMinor, visible: row.truth.visible, structured: row.truth.structured ?? null }));
    const snapshotId = `product-${semanticHash.slice(0, 32)}`;
    snapshotByRow.set(row.rowKey, snapshotId);
    if (!snapshots.has(snapshotId)) snapshots.set(snapshotId, { snapshotId, productKey: row.productKey, name: row.name, sizeText: row.sizeText, ...(row.taxonomyPath ? { taxonomyPath: row.taxonomyPath } : {}), purchasePriceMinor: row.purchasePriceMinor, semanticHash, canonicalRowKey: row.rowKey });
  }
  const discoveryEdges = accuracy.discoveryRows.map((row) => ({ rowKey: row.rowKey, termKey: row.termKey, query: row.query, snapshotId: snapshotByRow.get(row.rowKey)!, discoveryHash: row.discoveryHash, riskReasons: row.riskReasons, verificationRequired: row.verificationRequired }));
  const groupedReads = new Map<string, ProductEvidence["verificationReads"][number]>();
  for (const verification of accuracy.verifications) {
    const snapshotId = snapshotByRow.get(verification.rowKey);
    if (!snapshotId) continue;
    const key = stableJson([snapshotId, verification.observedAt, verification.outcome]);
    const prior = groupedReads.get(key);
    if (prior) prior.satisfies.push({ rowKey: verification.rowKey, discoveryHash: verification.discoveryHash });
    else groupedReads.set(key, { snapshotId, observedAt: verification.observedAt, outcome: verification.outcome, satisfies: [{ rowKey: verification.rowKey, discoveryHash: verification.discoveryHash }] });
  }
  const productSnapshots = [...snapshots.values()];
  const verificationReads = [...groupedReads.values()];
  const content = {
    version: 1 as const, productSnapshots, discoveryEdges, verificationReads,
    immutableShards: chunks.map((chunk) => ({ id: chunk.id, phase: chunk.phase, sha256: chunk.sha256, rowCount: chunk.rowCount, verificationCount: chunk.verificationCount })),
    uniqueProducts: productSnapshots.length, duplicateProductReferences: discoveryEdges.length - productSnapshots.length,
    productReadsRequired: new Set(discoveryEdges.filter((edge) => edge.verificationRequired).map((edge) => edge.snapshotId)).size,
    rowVerificationsSatisfied: verificationReads.reduce((total, read) => total + read.satisfies.length, 0),
    operationalProjection: {
      discoveryRows: discoveryEdges.length,
      retainedRows,
      omittedRows: Math.max(0, discoveryEdges.length - retainedRows),
      policy: "authored-matches-plus-verified-risk" as const,
    },
  };
  return { ...content, contentHash: await digestHex(stableJson(content)) };
}

function centralDateKey(instant: string): string {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Chicago", year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date(instant));
  const values = Object.fromEntries(parts.filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

async function buildDailyShards(state: LoadedSessionState, terms: BrowserCaptureSessionV2["terms"]): Promise<BrowserCaptureSessionV2["dailyShards"]> {
  const termByKey = new Map(terms.map((term) => [term.termKey, term]));
  const groups = new Map<string, BrowserCaptureSessionV2["chunks"]>();
  for (const chunk of state.chunkEntries) {
    const observedAt = chunk.termKeys.map((key) => termByKey.get(key)?.finishedAt).filter((value): value is string => Boolean(value)).sort().at(-1) ?? chunk.createdAt;
    const date = centralDateKey(observedAt);
    const values = groups.get(date) ?? [];
    values.push(chunk);
    groups.set(date, values);
  }
  const shards = [] as BrowserCaptureSessionV2["dailyShards"];
  for (const [ordinal, [date, chunks]] of [...groups.entries()].sort(([left], [right]) => left.localeCompare(right)).entries()) {
    const shardTerms = [...new Set(chunks.flatMap((chunk) => chunk.termKeys))].map((key) => termByKey.get(key)).filter((term): term is BrowserCaptureSessionV2["terms"][number] => Boolean(term));
    const instants = [...shardTerms.flatMap((term) => [term.startedAt, term.finishedAt]), ...chunks.map((chunk) => chunk.createdAt)].sort();
    const contentHash = await digestHex(stableJson(chunks.map((chunk) => ({ id: chunk.id, phase: chunk.phase, sha256: chunk.sha256, rowCount: chunk.rowCount, verificationCount: chunk.verificationCount }))));
    shards.push({
      date, ordinal, contentHash, termCount: shardTerms.length,
      rowCount: chunks.reduce((sum, chunk) => sum + chunk.rowCount, 0), chunkCount: chunks.length,
      firstObservedAt: instants[0]!, lastObservedAt: instants.at(-1)!,
    });
  }
  return shards;
}

function retainedOperationalRows(
  rows: Array<Record<string, unknown>>,
  accuracy: Awaited<ReturnType<typeof buildBrowserCaptureAccuracy>>,
): Array<Record<string, unknown>> {
  if (rows.length !== accuracy.discoveryRows.length) throw new Error("capture accuracy row order no longer agrees with discovery evidence");
  const retained = rows.filter((_row, index) => {
    const evidence = accuracy.discoveryRows[index]!;
    return evidence.matchEligible === true || evidence.verificationRequired || evidence.riskReasons.includes("likely-board-winner");
  });
  if (retained.length === 0) throw new Error("operational projection removed every captured product");
  return retained;
}

export async function buildCaptureVerificationPlan(directory: string, outputFile: string): Promise<Record<string, unknown>> {
  const draft = await loadDraft(directory);
  const state = await loadSessionState(directory, draft);
  const terms = finalizedTerms(draft, state.latest);
  const accuracy = await buildBrowserCaptureAccuracy(draft.store, accuracyCandidates(draft, state), state.verifications, terms);
  const required = accuracy.discoveryRows.filter((row) => row.verificationRequired);
  const grouped = new Map<string, typeof required>();
  for (const row of required) {
    const key = stableJson([row.productKey, row.name, row.sizeText, row.purchasePriceMinor, row.truth.visible.priceSemantics ?? null]);
    const rows = grouped.get(key) ?? [];
    rows.push(row);
    grouped.set(key, rows);
  }
  const targets = [...grouped.values()].map((rows) => {
    const primary = rows[0]!;
    return {
      rowKey: primary.rowKey, discoveryHash: primary.discoveryHash, termKey: primary.termKey, query: primary.query,
      discoveryCapturedAt: primary.truth.capturedAt, productKey: primary.productKey, name: primary.name,
      sizeText: primary.sizeText, purchasePriceMinor: primary.purchasePriceMinor, pageUrl: primary.truth.pageUrl,
      riskReasons: [...new Set(rows.flatMap((row) => row.riskReasons))],
      satisfies: rows.map((row) => ({ rowKey: row.rowKey, discoveryHash: row.discoveryHash, termKey: row.termKey, query: row.query, discoveryCapturedAt: row.truth.capturedAt })),
    };
  });
  const content = { version: 2, sessionId: draft.sessionId, sourceId: draft.sourceId, createdAt: new Date().toISOString(), targets };
  await atomicJson(outputFile, { ...content, contentHash: await digestHex(stableJson(content)) });
  replaceSessionWorkUnits(directory, draft.store, "verification", targets.map((target, ordinal) => ({
    key: target.rowKey,
    ordinal,
    priority: target.riskReasons.length + (targets.length - ordinal),
    payload: target,
  })), content.createdAt);
  completeSessionWorkUnits(directory, "verification", state.verifications.map((verification) => verification.rowKey));
  return { ok: true, outputFile, productReads: targets.length, rowTargets: required.length, verificationReuse: required.length - targets.length, discoveryRows: accuracy.discoveryRows.length };
}

export async function finalizeCaptureSession(directory: string, projectedOutputFile: string, manifestOutputFile: string, finishedAt = new Date().toISOString()): Promise<BrowserCaptureSessionV2> {
  const draft = await loadDraft(directory);
  if (draft.chunks.length === 0) throw new Error("cannot finalize a browser capture session without chunks");
  const state = await loadSessionState(directory, draft);
  const terms = finalizedTerms(draft, state.latest);
  const mergedRows = draft.worklist.flatMap((term) => state.latest.get(term.query)?.rows ?? []);
  if (mergedRows.length === 0) throw new Error("capture session contains no projected product rows");
  const accuracy = await buildBrowserCaptureAccuracy(draft.store, accuracyCandidates(draft, state), state.verifications, terms);
  const operationalRows = retainedOperationalRows(mergedRows, accuracy);
  const projectedCaptureSha256 = await renderProjectedCapture(draft.store, operationalRows, projectedOutputFile, draft.worklist);
  const coverageMode: BrowserCaptureSessionV2["coverageMode"] = terms.every((term) => term.outcome === "success" || term.outcome === "empty") && accuracy.pass ? "full" : "partial";
  const productEvidence = await buildProductEvidence(accuracy, state.chunkEntries, operationalRows.length);
  const dailyShards = await buildDailyShards(state, terms);
  const manifestContent = {
    version: 2 as const,
    sessionId: draft.sessionId,
    store: draft.store,
    sourceId: draft.sourceId,
    worklistHash: draft.worklistHash,
    ...(draft.adapter ? { adapter: { id: draft.adapter.id, version: draft.adapter.version, sha256: draft.adapter.sha256, capabilities: draft.adapter.capabilities } } : {}),
    startedAt: draft.startedAt,
    finishedAt,
    coverageMode,
    expectedTerms: draft.worklist.length,
    terms,
    canaries: state.canaries,
    chunks: state.chunkEntries,
    accuracy,
    productEvidence,
    dailyShards,
    projectedCaptureSha256,
  };
  const manifest = browserCaptureSessionSchema.parse({ ...manifestContent, contentHash: await digestHex(stableJson(manifestContent)) });
  if (manifest.version !== 2) throw new Error("capture session manifest unexpectedly downgraded");
  setCaptureSessionPhase(draft.sessionId, "finalized", finishedAt);
  await atomicJson(manifestOutputFile, manifest, false);
  if (draft.plannerHistoryFile) {
    const history = Object.fromEntries(draft.worklist.map((term) => {
      const captured = state.latest.get(term.query);
      const identities = (captured?.rows ?? []).map((row) => projectedIdentity(draft.store, row).productKey);
      return [queryIdentity(term.query), {
        distinctProducts: new Set(identities).size,
        duplicateProducts: identities.length - new Set(identities).size,
        durationMs: captured ? Math.max(0, Date.parse(captured.result.finishedAt) - Date.parse(captured.result.startedAt)) : 0,
        complete: captured ? ["success", "empty"].includes(captured.result.outcome) : false,
        observedAt: finishedAt,
      }];
    }));
    await atomicJson(draft.plannerHistoryFile, history);
    replacePlannerJournal(draft.plannerHistoryNamespace ?? path.resolve(draft.plannerHistoryFile).toLowerCase(), history, finishedAt);
  }
  replaceCatalogSnapshot(draft.store, accuracy.discoveryRows.map((row) => ({
    productKey: row.productKey, queryKey: queryIdentity(row.query), name: row.name, sizeText: row.sizeText,
    taxonomyPath: row.taxonomyPath ?? null, purchasePriceMinor: row.purchasePriceMinor,
    observedAt: row.truth.capturedAt, pageUrl: row.truth.pageUrl,
  })), finishedAt);
  return manifest;
}

export async function captureSessionStatus(directory: string): Promise<Record<string, unknown>> {
  const draft = await loadDraft(directory);
  const state = await loadSessionState(directory, draft);
  const terms = finalizedTerms(draft, state.latest);
  const candidates = accuracyCandidates(draft, state);
  const accuracy = candidates.length ? await buildBrowserCaptureAccuracy(draft.store, candidates, state.verifications, terms) : null;
  const remainingTerms = draft.worklist.filter((term) => !state.latest.has(term.query));
  const retryTerms = draft.worklist.filter((term) => ["blocked", "rejected"].includes(state.latest.get(term.query)?.result.outcome ?? ""));
  let rollingDiscovery: ReturnType<typeof rollingDiscoveryTarget> | null = null;
  try { rollingDiscovery = rollingDiscoveryTarget(draft.worklist.length); } catch { /* outside the Wed-Sat discovery window */ }
  const previewLimit = 20;
  const sourceTruthFailures = accuracy?.discoveryRows.flatMap((row) => {
    const identityPass = browserCaptureTruthPass(draft.store, {
      productKey: row.productKey,
      name: row.name,
      sizeText: row.sizeText,
      purchasePriceMinor: row.purchasePriceMinor,
    }, row.truth);
    const queryPass = row.truth.pageState?.pageType !== "search_results"
      || normalizeName(row.truth.pageState.query ?? "") === normalizeName(row.query);
    if (identityPass && queryPass) return [];
    return [{
      rowKey: row.rowKey,
      termKey: row.termKey,
      query: row.query,
      productKey: row.productKey,
      reason: !identityPass ? "source-truth-disagreement" : "search-query-disagreement",
      pageQuery: row.truth.pageState?.query ?? null,
    }];
  }) ?? [];
  return {
    ok: true,
    sessionId: draft.sessionId,
    store: draft.store,
    adapter: draft.adapter ? { id: draft.adapter.id, version: draft.adapter.version, sha256: draft.adapter.sha256 } : null,
    expectedTerms: draft.worklist.length,
    attemptedTerms: state.latest.size,
    rollingDiscovery: rollingDiscovery ? {
      ...rollingDiscovery,
      attempted: state.latest.size,
      targetReached: state.latest.size >= rollingDiscovery.cumulativeTarget,
      remainingToTarget: Math.max(0, rollingDiscovery.cumulativeTarget - state.latest.size),
    } : null,
    remainingTermCount: remainingTerms.length,
    remainingTerms: remainingTerms.slice(0, previewLimit),
    remainingTermsTruncated: remainingTerms.length > previewLimit,
    retryTermCount: retryTerms.length,
    retryTerms: retryTerms.slice(0, previewLimit),
    retryTermsTruncated: retryTerms.length > previewLimit,
    chunks: draft.chunks.length,
    discoveryRows: candidates.length,
    verificationTargets: accuracy?.requiredVerificationRows ?? 0,
    matchedVerifications: accuracy?.matchedVerificationRows ?? 0,
    unresolvedVerifications: accuracy?.unresolvedVerificationRows ?? 0,
    uniqueProducts: accuracy ? new Set(accuracy.discoveryRows.map((row) => row.productKey)).size : 0,
    duplicateProductReferences: accuracy ? accuracy.discoveryRows.length - new Set(accuracy.discoveryRows.map((row) => row.productKey)).size : 0,
    productReadsRequired: accuracy ? new Set(accuracy.discoveryRows.filter((row) => row.verificationRequired).map((row) => row.productKey)).size : 0,
    retrievalCompleteTerms: accuracy?.retrievalCompleteTerms ?? 0,
    sourceTruthFailureCount: sourceTruthFailures.length,
    sourceTruthFailures: sourceTruthFailures.slice(0, previewLimit),
    sourceTruthFailuresTruncated: sourceTruthFailures.length > previewLimit,
    accuracyPass: accuracy?.pass ?? false,
    evidence: sessionEvidence(directory),
  };
}

export async function retainCaptureSessionEvidence(directory: string, evidenceFile: string, kind = "screenshot"): Promise<Record<string, unknown>> {
  const draft = await loadDraft(directory);
  const body = new Uint8Array(await readFile(evidenceFile));
  const sha256 = await digestHex(body);
  const extension = path.extname(evidenceFile).toLowerCase();
  const contentType = extension === ".png" ? "image/png" : extension === ".jpg" || extension === ".jpeg" ? "image/jpeg" : extension === ".webp" ? "image/webp" : "application/octet-stream";
  const id = `evidence-${sha256.slice(0, 32)}`;
  storeSessionEvidence(directory, { id, kind, file: path.basename(evidenceFile), sha256, contentType, body, createdAt: new Date().toISOString() });
  await persistDraft(directory, draft);
  return { ok: true, id, kind, sha256, byteLength: body.byteLength, contentType };
}
