import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { directCaptureArtifactSchema, ingredientPriceResearchSchema, observationChunkSchema } from "@thriftycrew/contracts";
import { deployConfiguration, ingestDirectCapture, MutationClient, publishNativeRelease, replayCurrentArtifact, type CaptureEvidenceInput } from "@thriftycrew/daily/client";
import { buildCurrentBridge } from "@thriftycrew/daily/legacy";
import { buildRegularCapture, type CaptureAttestation } from "@thriftycrew/daily/direct";
import { evaluateSourceContract, type SourceContract } from "@thriftycrew/daily/source-contracts";
import { buildNativeRelease, loadNativeReleaseCatalog, nativeReleaseIdentity } from "@thriftycrew/daily/native";
import type { ContentAddressedReleaseGraph } from "@thriftycrew/daily/release-graph";
import { digestHex, normalizeName, stableJson } from "@thriftycrew/domain";
import { generateLegacyConfiguration } from "./config";
import { buildNativeParityReport, compileProductMatcher, decodeNativeEngineSnapshot, evaluateAisleFamilyEvidence, type AisleFamily, type NativeEngineSnapshot, type TupleEncodedNativeEngineSnapshot } from "@thriftycrew/engine";
import { checkScheduleAuthority, readScheduleAuthority } from "./schedules";
import { checkAgentRegistry, readAgentRegistry } from "./agents";
import { browserCaptureCycleStatus, captureQueueStatus, compactPromotedCaptureQueue, defaultCaptureQueueRoot, enqueueCapture, reconcileCaptureQueueRemote, verifyCaptureQueueFilesystem } from "./capture-queue";
import { drainBrowserCaptureQueue } from "./capture-drainer";
import { checkpointCaptureJournal, restoreCaptureJournal } from "./capture-journal-checkpoint";
import { findLatestRegularCapture, omahaDateKey, parseServerCaptureStore, readFreshRegularCapture, SERVER_CAPTURE_STORES } from "./current-captures";
import { abandonCaptureSession, appendCaptureChunk, buildCaptureSessionWorklist, buildCaptureVerificationPlan, captureSessionStatus, finalizeCaptureSession, initializeCaptureSession, retainCaptureSessionEvidence } from "./capture-session";
import { captureControllerRequest } from "../../../scripts/capture-controller-client.mjs";
import { catalogRefreshPlan } from "./capture-journal";
import { agentJobRunFields } from "./job-run";
import { loadR2ShardedEngineSnapshot } from "./engine-snapshot";
import { compileCommodityRegexPattern, normalizeCommodityRegexPattern, parseCatalogJson } from "./commodity-regex";

const platformRoot = path.resolve(import.meta.dirname, "../../..");
const incomeRoot = path.resolve(platformRoot, "..");
const invocationRoot = path.resolve(process.env.INIT_CWD ?? process.cwd());
const [command = "help", subcommand, ...arguments_] = process.argv.slice(2);

function cliPath(file: string): string {
  return path.normalize(path.isAbsolute(file) ? file : path.resolve(invocationRoot, file));
}

interface LocalAdSchedule {
  updated?: string;
  stores?: Array<{ store?: string; method?: string; cadence_days?: number | null; current?: { from?: string; to?: string } | null; next_pull?: string | null }>;
}

const AD_STORE_LABELS: Record<string, string> = {
  aldi: "Aldi", bakers: "Baker's", "family-fare": "Family Fare", fareway: "Fareway", "hy-vee": "Hy-Vee",
};

async function bindDetectedAdWindow(store: string, document: Record<string, unknown>): Promise<Record<string, unknown>> {
  if (document.ad_from || document.ad_to || !AD_STORE_LABELS[store]) return document;
  try {
    const schedule = JSON.parse(await readFile(path.join(incomeRoot, "grocery", "ad-schedule.json"), "utf8")) as LocalAdSchedule;
    const label = AD_STORE_LABELS[store]!;
    const policy = PROMOTION_STORES[label];
    const authored = schedule.stores?.find((entry) => entry.store === label)?.current;
    const today = dateKey(new Date());
    const current = authored?.from && authored.to && authored.to >= today
      ? { from: authored.from, to: authored.to }
      : policy ? predictedWeeklyWindow(today, policy.expectedStartWeekday) : undefined;
    if (!current) return document;
    return { ...document, ad_from: current.from, ad_to: current.to };
  } catch {
    // Missing schedule evidence does not invent a window. The promotion guard
    // will keep undated ad-only offers out of publication.
    return document;
  }
}

const PROMOTION_STORES: Record<string, { storeLocationId: string; captureLane: "headless" | "browser"; expectedStartWeekday: number }> = {
  "Family Fare": { storeLocationId: "family-fare-omaha-6401", captureLane: "headless", expectedStartWeekday: 0 },
  Fareway: { storeLocationId: "fareway-omaha-043", captureLane: "browser", expectedStartWeekday: 0 },
  "Hy-Vee": { storeLocationId: "hy-vee-omaha-1465", captureLane: "headless", expectedStartWeekday: 1 },
  Aldi: { storeLocationId: "aldi-omaha-446-048", captureLane: "browser", expectedStartWeekday: 3 },
  "Baker's": { storeLocationId: "bakers-saddle-creek", captureLane: "headless", expectedStartWeekday: 3 },
};

function dateKey(date: Date): string {
  const values = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Chicago", year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(date).map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

function shiftDateKey(value: string, days: number): string {
  const [year, month, day] = value.split("-").map(Number);
  return new Date(Date.UTC(year!, month! - 1, day! + days)).toISOString().slice(0, 10);
}

function omahaMidnight(value: string): string {
  const noon = new Date(`${value}T12:00:00.000Z`);
  const zone = new Intl.DateTimeFormat("en-US", { timeZone: "America/Chicago", timeZoneName: "longOffset" })
    .formatToParts(noon).find((part) => part.type === "timeZoneName")?.value;
  const offset = zone?.match(/^GMT([+-]\d{2}:\d{2})$/)?.[1];
  if (!offset) throw new Error(`cannot resolve Omaha UTC offset for ${value}`);
  return new Date(`${value}T00:00:00${offset}`).toISOString();
}

function predictedWeeklyWindow(today: string, expectedStartWeekday: number): { from: string; to: string } {
  const weekday = new Date(`${today}T12:00:00Z`).getUTCDay();
  const from = shiftDateKey(today, -((weekday - expectedStartWeekday + 7) % 7));
  return { from, to: shiftDateKey(from, 6) };
}

async function localPromotionCalendarDocument() {
  const sourceFile = path.join(incomeRoot, "grocery", "ad-schedule.json");
  const source = JSON.parse((await readFile(sourceFile, "utf8")).replace(/^\uFEFF/, "")) as LocalAdSchedule;
  const observedAt = new Date().toISOString();
  const today = dateKey(new Date());
  const calendars = Object.entries(PROMOTION_STORES).map(([storeName, policy]) => {
    const entry = source.stores?.find((item) => item.store === storeName);
    const detected = entry?.current?.from && entry.current.to ? { from: entry.current.from, to: entry.current.to } : undefined;
    const current = detected && detected.to >= today ? detected : predictedWeeklyWindow(today, policy.expectedStartWeekday);
    return {
      ...policy, storeName,
      validFrom: omahaMidnight(current.from!),
      validTo: omahaMidnight(shiftDateKey(current.to!, 1)),
      evidence: {
        authority: "grocery/ad-schedule.json", scheduleUpdated: source.updated ?? null,
        detected: Boolean(detected && detected.to >= today), sourceMethod: entry?.method ?? null,
        sourceFrom: detected?.from ?? null, sourceToInclusive: detected?.to ?? null,
        nextPull: entry?.next_pull ?? null, intervalPolicy: "half-open",
      },
    };
  });
  return { observedAt, calendars };
}

async function githubOidcToken(): Promise<string | undefined> {
  const requestUrl = process.env.ACTIONS_ID_TOKEN_REQUEST_URL;
  const requestToken = process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN;
  if (!requestUrl || !requestToken) return undefined;
  const audience = process.env.TC_OIDC_AUDIENCE ?? "tc-grocery-v3";
  const url = new URL(requestUrl);
  url.searchParams.set("audience", audience);
  const response = await fetch(url, { headers: { authorization: `Bearer ${requestToken}` } });
  if (!response.ok) throw new Error(`GitHub OIDC token request returned ${response.status}`);
  const payload = await response.json() as { value?: string };
  if (!payload.value) throw new Error("GitHub OIDC response omitted the token");
  return payload.value;
}

async function mutationClient(): Promise<MutationClient> {
  const oidcToken = process.env.TC_OIDC_TOKEN;
  const canRequestOidcToken = Boolean(process.env.ACTIONS_ID_TOKEN_REQUEST_URL && process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN);
  const secret = process.env.TC_LOCAL_MUTATION_SECRET;
  let executionFence: { runId: string; fence: number } | undefined;
  if (process.env.TC_JOB_LEASE_FILE) {
    try {
      const parsed = JSON.parse(await readFile(process.env.TC_JOB_LEASE_FILE, "utf8")) as { runId?: unknown; lease?: { fence?: unknown } };
      if (typeof parsed.runId === "string" && typeof parsed.lease?.fence === "number") executionFence = { runId: parsed.runId, fence: parsed.lease.fence };
    } catch { /* Job start intentionally runs before the lease file exists. */ }
  }
  if (!oidcToken && !canRequestOidcToken && !secret) throw new Error("set TC_LOCAL_MUTATION_SECRET locally or run from a GitHub OIDC-enabled job");
  return new MutationClient({
    origin: process.env.TC_API_ORIGIN ?? "http://127.0.0.1:8787",
    agentId: process.env.TC_AGENT_ID ?? "local-operator",
    ...(executionFence ? { jobRunId: executionFence.runId, leaseFence: executionFence.fence } : {}),
    ...(oidcToken ? { oidcToken } : canRequestOidcToken ? { oidcTokenProvider: async () => {
      const refreshed = await githubOidcToken();
      if (!refreshed) throw new Error("GitHub OIDC token refresh was unavailable");
      return refreshed;
    } } : { secret }),
  });
}

async function loadCurrentReleaseGraph(client: MutationClient): Promise<ContentAddressedReleaseGraph | undefined> {
  const nodes: ContentAddressedReleaseGraph["nodes"] = [];
  let afterKind = "";
  let afterKey = "";
  let header: { parentReleaseId: string | null; dependencyHash: string } | null = null;
  while (true) {
    const query = new URLSearchParams({ marketId: "omaha" });
    if (afterKind) { query.set("afterKind", afterKind); query.set("afterKey", afterKey); }
    const page = await client.request(`/internal/engine/current-release-graph?${query}`, { acceptStatuses: [404] }) as unknown as {
      httpStatus?: number; parentReleaseId: string | null; dependencyHash: string;
      nodes?: ContentAddressedReleaseGraph["nodes"]; next?: { kind: string; key: string } | null;
    };
    if (page.httpStatus === 404) return undefined;
    header ??= { parentReleaseId: page.parentReleaseId, dependencyHash: page.dependencyHash };
    nodes.push(...(page.nodes ?? []));
    if (!page.next) break;
    afterKind = page.next.kind;
    afterKey = page.next.key;
  }
  return { version: 1, parentReleaseId: header?.parentReleaseId ?? null,
    dependencyHash: header?.dependencyHash ?? "0".repeat(64), nodes };
}

async function loadEngineSnapshot(
  client: MutationClient,
  mode: "legacy" | "direct" | "all",
  profile: "release" | "parity" = "release",
  observedAt?: string,
): Promise<NativeEngineSnapshot> {
  try {
    return await loadR2ShardedEngineSnapshot(client, mode, profile, observedAt);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.warn(`R2-sharded snapshot unavailable; using verified D1 rollback path: ${message}`);
    const query = new URLSearchParams({ mode, profile });
    if (observedAt) query.set("observedAt", observedAt);
    return decodeNativeEngineSnapshot(await client.request(`/internal/engine/snapshot?${query}`) as unknown as TupleEncodedNativeEngineSnapshot);
  }
}

async function publicGet(pathname: string): Promise<unknown> {
  const response = await fetch(new URL(pathname, process.env.TC_API_ORIGIN ?? "http://127.0.0.1:8787"));
  const body = await response.json();
  if (!response.ok) throw new Error(`${pathname} returned ${response.status}`);
  return body;
}

function githubRunId(job: string): string {
  const explicit = process.env.TC_JOB_RUN_ID;
  if (explicit) return explicit;
  const run = process.env.GITHUB_RUN_ID ?? `local-${Date.now()}`;
  const attempt = process.env.GITHUB_RUN_ATTEMPT ?? "1";
  return `run_${job}_${run}_${attempt}`;
}

async function writeJson(file: string, value: unknown): Promise<void> {
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

interface MatchProductRow {
  product_id: string;
  external_key: string;
  store_location_id: string;
  name: string;
  normalized_name: string;
  taxonomy_path: string | null;
  normalized_basis_unit: string;
  normalized_basis_qty_micros: number;
}

interface MatchContext {
  matcher: ReturnType<typeof compileProductMatcher>;
  categoryByCommodity: Map<string, string>;
  nonFoodFamilies: Set<string>;
}

async function loadMatchContext(): Promise<MatchContext> {
  const commodities = JSON.parse(await readFile(path.join(platformRoot, "config", "commodities.json"), "utf8")) as Array<{ id: string; include?: string[]; exclude?: string[] }>;
  const categoryDocument = JSON.parse((await readFile(path.join(platformRoot, "config", "categories.json"), "utf8")).replace(/^\uFEFF/, "")) as { categories: Array<{ key: string; commodities: string[] }> };
  return {
    categoryByCommodity: new Map(categoryDocument.categories.flatMap((category) => category.commodities.map((commodityId) => [commodityId, category.key] as const))),
    nonFoodFamilies: new Set(["household", "personal", "baby", "pet"]),
    matcher: compileProductMatcher(commodities.map((commodity, index) => ({
      commodityId: commodity.id,
      includes: commodity.include ?? [],
      excludes: commodity.exclude ?? [],
      // Preserve the production engine's documented first-match-wins semantics
      // while making the precedence explicit and collision-testable.
      priority: commodities.length - index,
    }))),
  };
}

async function matchBatch(client: MutationClient, batchId: string, reusableContext?: MatchContext): Promise<Record<string, unknown>> {
  const snapshot = await client.request(`/internal/capture-batches/${encodeURIComponent(batchId)}/products`) as unknown as Record<string, unknown> & {
    sourceId: string; status: string; configurationId: string; configurationHash: string; products: MatchProductRow[];
  };
  if (!Array.isArray(snapshot.products)) throw new Error("matching snapshot omitted products");
  if (!(snapshot.status === "promoted" || snapshot.status === "superseded" || snapshot.status === "validated")) throw new Error(`batch ${batchId} cannot be matched from ${snapshot.status}`);
  const { matcher, categoryByCommodity, nonFoodFamilies } = reusableContext ?? await loadMatchContext();
  const decisions: Array<{ productId: string; commodityId: string; configurationId: string; decidedBy: "rule" | "aisle"; reason: string }> = [];
  const unmatched: Array<Record<string, unknown>> = [];
  const collisions: Array<Record<string, unknown>> = [];
  const aisleRejected: Array<Record<string, unknown>> = [];
  for (const product of snapshot.products) {
    const outcome = matcher(product.name);
    if (outcome.status === "collision") {
      collisions.push({ productId: product.product_id, name: product.name, candidates: outcome.candidates });
      continue;
    }
    if (outcome.status === "unmatched" || !outcome.commodityId) {
      unmatched.push({ productId: product.product_id, name: product.name });
      continue;
    }
    const category = categoryByCommodity.get(outcome.commodityId) ?? "food";
    const expectedFamily: AisleFamily = nonFoodFamilies.has(category) ? category as AisleFamily : "food";
    const additionalAllowedFamilies: AisleFamily[] = [];
    if (outcome.commodityId === "protein-bars" || outcome.commodityId === "hand-soap") additionalAllowedFamilies.push("personal");
    if (outcome.commodityId === "facial-tissues") additionalAllowedFamilies.push("household");
    const aisle = evaluateAisleFamilyEvidence(product.taxonomy_path ?? undefined, expectedFamily, additionalAllowedFamilies);
    if (aisle.status === "rejected") {
      aisleRejected.push({ productId: product.product_id, name: product.name, commodityId: outcome.commodityId, taxonomyPath: product.taxonomy_path, reason: aisle.reason });
      continue;
    }
    decisions.push({
      productId: product.product_id,
      commodityId: outcome.commodityId,
      configurationId: snapshot.configurationId,
      decidedBy: aisle.status === "confirmed" ? "aisle" : "rule",
      reason: `Authored first-match rule precedence${product.taxonomy_path ? `; shelf taxonomy examined: ${aisle.reason}` : "; no shelf taxonomy supplied"}`,
    });
  }
  const inputMaterial = {
    batchId,
    sourceId: snapshot.sourceId,
    configurationId: snapshot.configurationId,
    configurationHash: snapshot.configurationHash,
    products: snapshot.products.map((product) => [product.product_id, product.normalized_name, product.taxonomy_path]),
    decisions: decisions.map((decision) => [decision.productId, decision.commodityId, decision.decidedBy]),
  };
  const inputHash = await digestHex(stableJson(inputMaterial));
  const report = {
    id: `match_${inputHash.slice(0, 32)}`,
    batchId,
    configurationId: snapshot.configurationId,
    inputHash,
    productCount: snapshot.products.length,
    matchedCount: decisions.length,
    unmatchedCount: unmatched.length,
    collisionCount: collisions.length,
    aisleRejectedCount: aisleRejected.length,
    detail: {
      sourceId: snapshot.sourceId,
      precedence: "authored commodity order",
      unmatchedExamples: unmatched.slice(0, 100),
      collisionExamples: collisions.slice(0, 100),
      aisleRejectedExamples: aisleRejected.slice(0, 100),
    } as Record<string, unknown>,
  };
  const existing = await client.request(`/internal/match-runs/${encodeURIComponent(report.id)}`, { acceptStatuses: [404] }) as {
    found?: boolean; run?: { input_hash?: string; status?: string };
  };
  if (existing.found) {
    if (existing.run?.input_hash !== inputHash) throw new Error(`match run ${report.id} has a conflicting input hash`);
    return { ok: existing.run.status === "passed", runId: report.id, status: existing.run.status, idempotent: true, reused: true, ...report };
  }
  let decisionWrites = 0;
  let superseded = 0;
  let unchanged = 0;
  for (let offset = 0; offset < decisions.length; offset += 250) {
    const result = await client.request("/internal/match-decisions", { method: "PUT", json: { decisions: decisions.slice(offset, offset + 250) } }) as {
      decisionWrites?: number; superseded?: number; unchanged?: number;
    };
    decisionWrites += result.decisionWrites ?? 0;
    superseded += result.superseded ?? 0;
    unchanged += result.unchanged ?? 0;
  }
  const reconciliation = await client.request("/internal/match-decisions/reconcile", { json: {
    batchId,
    configurationId: snapshot.configurationId,
    retainedProductIds: decisions.map((decision) => decision.productId),
  } }) as { superseded?: number };
  report.detail.efficiency = {
    submitted: decisions.length,
    decisionWrites,
    superseded,
    reconciledSuperseded: reconciliation.superseded ?? 0,
    unchanged,
    writeAvoidanceRatio: decisions.length === 0 ? 1 : unchanged / decisions.length,
  };
  const persisted = await client.request("/internal/match-runs", { method: "POST", json: report, acceptStatuses: [422] });
  return { ...persisted, ...report };
}

async function rematchPromotedBatches(client: MutationClient, verbose = false): Promise<Record<string, unknown>> {
  const startedAt = performance.now();
  const listed = await client.request("/internal/capture-batches/promoted") as {
    batches?: Array<{ id: string; source_id: string; captured_to: string; has_active_match?: number }>;
  };
  const context = await loadMatchContext();
  const batches: Array<Record<string, unknown>> = [];
  const selected = listed.batches ?? [];
  const pending = selected.filter((batch) => Number(batch.has_active_match ?? 0) !== 1);
  const summary = { selected: selected.length, alreadyBound: selected.length - pending.length, checked: 0, reused: 0, rebuilt: 0, failed: 0, products: 0, matched: 0, decisionWrites: 0, unchanged: 0 };
  for (const batch of pending) {
    const matching = await matchBatch(client, batch.id, context);
    summary.checked += 1;
    summary.products += Number(matching.productCount ?? 0);
    summary.matched += Number(matching.matchedCount ?? 0);
    if (matching.reused) summary.reused += 1;
    else summary.rebuilt += 1;
    const efficiency = (matching.detail as { efficiency?: { decisionWrites?: number; unchanged?: number } } | undefined)?.efficiency;
    summary.decisionWrites += Number(efficiency?.decisionWrites ?? 0);
    summary.unchanged += Number(efficiency?.unchanged ?? 0);
    if (matching.status !== "passed") {
      summary.failed += 1;
      throw new Error(`promoted batch ${batch.id} failed matching under the active configuration`);
    }
    batches.push({ ...batch, matching });
  }
  return {
    ok: true,
    summary: { ...summary, elapsedMs: Math.round(performance.now() - startedAt) },
    ...(verbose ? { batches } : {}),
  };
}

interface CommodityAddition {
  id?: string; label?: string; unit?: string; include?: string[]; exclude?: string[]; categoryId?: string; searchTerms?: string[];
  bandMin?: number; bandMax?: number;
}

async function commodityAddSpecification(incoming: CommodityAddition): Promise<unknown> {
  if (!incoming.id || !/^[a-z0-9][a-z0-9-]{1,79}$/.test(incoming.id) || !incoming.label?.trim() || !incoming.categoryId) throw new Error("commodity file needs a safe id, label, unit, and categoryId");
  const allowedUnits = new Set(["lb", "oz", "fl_oz", "each", "dozen", "gal", "qt", "pt", "liter", "ml", "gram", "kg"]);
  if (!incoming.unit || !allowedUnits.has(incoming.unit)) throw new Error(`commodity ${incoming.id} has an unsupported basis unit`);
  const include = [...new Set((incoming.include ?? []).map(normalizeCommodityRegexPattern).filter(Boolean))];
  const exclude = [...new Set((incoming.exclude ?? []).map(normalizeCommodityRegexPattern).filter(Boolean))];
  const searchTerms = [...new Set((incoming.searchTerms ?? []).map((value) => value.trim()).filter(Boolean))];
  if (include.length === 0 || searchTerms.length === 0) throw new Error(`commodity ${incoming.id} needs at least one include regex and one search term`);
  for (const [kind, patterns] of [["include", include], ["exclude", exclude]] as const) {
    for (const pattern of patterns) {
      if (pattern.length > 500) throw new Error(`${kind} regex is too long for ${incoming.id}`);
      try { compileCommodityRegexPattern(pattern); } catch (error) { throw new Error(`${kind} regex is invalid for ${incoming.id}: ${error instanceof Error ? error.message : String(error)}`); }
    }
  }
  const commodityFile = path.join(platformRoot, "config", "commodities.json");
  const categoryFile = path.join(platformRoot, "config", "categories.json");
  const searchFile = path.join(incomeRoot, "grocery", "commodity-search.json");
  const commodities = parseCatalogJson<Array<Record<string, unknown>>>(await readFile(commodityFile, "utf8"));
  if (commodities.some((item) => item.id === incoming.id)) throw new Error(`commodity ${incoming.id} already exists`);
  if (commodities.some((item) => normalizeName(String(item.label ?? "")) === normalizeName(incoming.label!))) throw new Error(`commodity label ${incoming.label} already exists`);
  const proposedNames = [incoming.label!, ...searchTerms];
  const newIncludes = include.map(compileCommodityRegexPattern);
  const newExcludes = exclude.map(compileCommodityRegexPattern);
  if (!proposedNames.some((name) => newIncludes.some((pattern) => pattern.test(name)) && !newExcludes.some((pattern) => pattern.test(name)))) {
    throw new Error(`commodity ${incoming.id} include rules do not positively identify its own label or search terms`);
  }
  for (const existing of commodities) {
    const existingLabel = String(existing.label ?? "");
    if (newIncludes.some((pattern) => pattern.test(existingLabel)) && !newExcludes.some((pattern) => pattern.test(existingLabel))) {
      throw new Error(`commodity ${incoming.id} include rules collide with existing commodity ${String(existing.id)}`);
    }
    const existingIncludes = Array.isArray(existing.include) ? existing.include.map((pattern) => compileCommodityRegexPattern(String(pattern))) : [];
    const existingExcludes = Array.isArray(existing.exclude) ? existing.exclude.map((pattern) => compileCommodityRegexPattern(String(pattern))) : [];
    if (proposedNames.some((name) => existingIncludes.some((pattern) => pattern.test(name)) && !existingExcludes.some((pattern) => pattern.test(name)))) {
      throw new Error(`existing commodity ${String(existing.id)} would also claim proposed commodity ${incoming.id}; operator matcher surgery is required`);
    }
  }
  if (incoming.bandMin !== undefined && (!Number.isFinite(incoming.bandMin) || incoming.bandMin <= 0)) throw new Error(`commodity ${incoming.id} has an invalid minimum price band`);
  if (incoming.bandMax !== undefined && (!Number.isFinite(incoming.bandMax) || incoming.bandMax <= (incoming.bandMin ?? 0))) throw new Error(`commodity ${incoming.id} has an invalid maximum price band`);
  commodities.push({
    id: incoming.id, label: incoming.label.trim(), unit: incoming.unit, include, exclude,
    ...(incoming.bandMin !== undefined ? { band_min: incoming.bandMin } : {}),
    ...(incoming.bandMax !== undefined ? { band_max: incoming.bandMax } : {}),
  });
  const categoryDocument = parseCatalogJson<{ categories: Array<{ key: string; commodities: string[] }> }>(await readFile(categoryFile, "utf8"));
  const category = categoryDocument.categories.find((item) => item.key === incoming.categoryId);
  if (!category) throw new Error(`category ${incoming.categoryId} does not exist`);
  category.commodities.push(incoming.id);
  const searchDocument = parseCatalogJson<{ note?: string; terms: Record<string, string> }>(await readFile(searchFile, "utf8"));
  if (searchDocument.terms[incoming.id]) throw new Error(`commodity search term ${incoming.id} already exists`);
  searchDocument.terms[incoming.id] = searchTerms[0]!;
  await writeJson(commodityFile, commodities);
  await writeJson(categoryFile, categoryDocument);
  await writeJson(searchFile, searchDocument);
  return { ...await generateLegacyConfiguration(incomeRoot, false), commodityId: incoming.id, searchTerm: searchTerms[0] };
}

async function commodityAdd(inputFile: string | undefined): Promise<unknown> {
  if (!inputFile) throw new Error("tc commodity add requires a JSON file");
  return commodityAddSpecification(JSON.parse(await readFile(cliPath(inputFile), "utf8")) as CommodityAddition);
}

async function recipeAdd(inputFile: string | undefined): Promise<unknown> {
  if (!inputFile) throw new Error("tc recipe add requires a JSON specification file");
  const specification = JSON.parse(await readFile(cliPath(inputFile), "utf8")) as { slug?: string; servings?: number; ingredients_grams?: unknown[] };
  if (!specification.slug || !/^[a-z0-9][a-z0-9-]*$/.test(specification.slug) || !Number.isInteger(specification.servings) || !Array.isArray(specification.ingredients_grams)) {
    throw new Error("recipe needs a safe slug, integer servings, and ingredients_grams");
  }
  const target = path.join(incomeRoot, "meal-prep", "db", "recipes", `${specification.slug}.json`);
  await access(target).then(() => { throw new Error(`recipe ${specification.slug} already exists`); }).catch((error: unknown) => {
    if (error instanceof Error && error.message.includes("already exists")) throw error;
  });
  await writeJson(target, specification);
  return { ok: true, target };
}

async function releaseFreezeDrill(): Promise<Record<string, unknown>> {
  const client = await mutationClient();
  const before = await publicGet("/api/v2/status") as { currentRelease?: { id?: string; summary?: { expectedCommodities?: number; expectedStores?: number; expectedRecipes?: number; expectedFreeRotation?: number } } };
  const currentReleaseId = before.currentRelease?.id;
  if (!currentReleaseId) throw new Error("release-freeze drill requires a published release");
  const snapshot = await loadEngineSnapshot(client, "direct");
  const observedAt = new Date().toISOString();
  const inputBatchIds = [...snapshot.inputBatchIds].sort();
  const inputManifest = {
    kind: "release-surface-freeze-drill",
    observedAt,
    currentReleaseId,
    snapshotInputHash: snapshot.inputHash,
  };
  const inputHash = await digestHex(stableJson({ inputManifest, inputBatchIds }));
  const releaseId = `rel_drill_${inputHash.slice(0, 20)}`;
  const summary = before.currentRelease?.summary ?? {};
  await client.request("/internal/releases", { json: {
    id: releaseId,
    marketId: "omaha",
    configurationId: snapshot.configurationId,
    inputManifest,
    inputBatchIds,
    inputHash,
    summary: {
      expectedCommodities: summary.expectedCommodities ?? snapshot.commodities.length,
      expectedStores: summary.expectedStores ?? snapshot.stores.length,
      expectedRecipes: summary.expectedRecipes ?? 542,
      expectedFreeRotation: summary.expectedFreeRotation ?? 20,
    },
  } });
  const validation = await client.request(`/internal/releases/${releaseId}/validate`, { method: "POST", acceptStatuses: [422] });
  if (validation.state !== "rejected") await client.request(`/internal/releases/${releaseId}/reject`, { method: "POST" });
  const publication = await client.request(`/internal/releases/${releaseId}/publish`, { method: "POST", acceptStatuses: [409, 422] });
  const after = await publicGet("/api/v2/status") as { currentRelease?: { id?: string } };
  const passed = validation.state === "rejected"
    && publication.ok === false
    && publication.httpStatus !== undefined
    && [409, 422].includes(Number(publication.httpStatus))
    && after.currentRelease?.id === currentReleaseId;
  const evidence = {
    drill: "release-surface-freeze",
    candidateReleaseId: releaseId,
    publishedReleaseBefore: currentReleaseId,
    publishedReleaseAfter: after.currentRelease?.id ?? null,
    validationState: validation.state,
    blockingGuards: validation.blockingGuards ?? [],
    publishHttpStatus: publication.httpStatus,
    pointerUnchanged: after.currentRelease?.id === currentReleaseId,
  };
  const date = observedAt.slice(0, 10);
  const recorded = await client.request("/internal/evidence-gates", {
    json: {
      id: `evidence_release-freeze_${inputHash.slice(0, 20)}`,
      gate: "chaos-drill",
      periodKey: `release-freeze-${date}`,
      sourceRef: releaseId,
      status: passed ? "pass" : "fail",
      observedAt,
      evidence,
    },
    acceptStatuses: [422],
  });
  return { ok: passed, ...evidence, evidenceEventId: recorded.eventId };
}

let result: unknown;
if (command === "status") {
  result = await publicGet("/api/v2/status");
} else if (command === "doctor") {
  result = await (await mutationClient()).request("/internal/doctor", { acceptStatuses: [422] });
} else if (command === "triage") {
  if (subcommand === "compact") {
    const execute = arguments_.includes("--execute");
    const client = await mutationClient();
    if (!execute) result = await client.request("/internal/triage/compact", { json: { execute: false, limit: 75 } });
    else {
      const archives: unknown[] = [];
      let resultCount = 0;
      let findingCount = 0;
      let triageCount = 0;
      for (let page = 0; page < 100; page++) {
        const compacted = await client.request("/internal/triage/compact", { json: { execute: true, limit: 75 } }) as {
          resultCount?: number; findingCount?: number; triageCount?: number; archiveId?: string; objectKey?: string; contentHash?: string;
        };
        const pageResults = Number(compacted.resultCount ?? 0);
        if (pageResults === 0) break;
        resultCount += pageResults;
        findingCount += Number(compacted.findingCount ?? 0);
        triageCount += Number(compacted.triageCount ?? 0);
        archives.push({ archiveId: compacted.archiveId, objectKey: compacted.objectKey, contentHash: compacted.contentHash, resultCount: pageResults });
      }
      result = { ok: true, executed: true, resultCount, findingCount, triageCount, archives };
    }
  } else if (subcommand === "run" || subcommand === "reconcile") {
    result = await (await mutationClient()).request(`/internal/triage/${subcommand}`, { method: "POST" });
  } else if (subcommand === "review") {
    const [triageId, outputFile] = arguments_;
    if (!triageId || !outputFile) throw new Error("tc triage review requires a triage id and output file");
    const packet = await (await mutationClient()).request(`/internal/triage/${encodeURIComponent(triageId)}/review`);
    const resolvedOutputFile = cliPath(outputFile);
    await writeJson(resolvedOutputFile, packet);
    result = { ok: true, triageId, outputFile: resolvedOutputFile, readOnly: true };
  } else if (subcommand === "plan" || subcommand === "resolve" || subcommand === "needs-operator") {
    const [triageId, file] = arguments_;
    if (!triageId || !file) throw new Error(`tc triage ${subcommand} requires a triage id and JSON file`);
    const resolution = JSON.parse(await readFile(cliPath(file), "utf8")) as Record<string, unknown>;
    const status = subcommand === "plan" ? "planned" : subcommand === "resolve" ? "resolved" : "needs_operator";
    const planRef = status === "planned" ? `sha256:${await digestHex(stableJson(resolution))}` : undefined;
    result = await (await mutationClient()).request(`/internal/triage/${encodeURIComponent(triageId)}/resolve`, { json: {
      status,
      ...(planRef ? { planRef } : {}),
      resolution,
    } });
  } else {
    const requestedStatus = !subcommand || subcommand === "status" ? "open" : subcommand;
    result = await (await mutationClient()).request(`/internal/triage?status=${encodeURIComponent(requestedStatus)}`);
  }
} else if (command === "config" && (subcommand === "generate" || subcommand === "check")) {
  result = await generateLegacyConfiguration(incomeRoot, subcommand === "check");
} else if (command === "config" && subcommand === "deploy") {
  await generateLegacyConfiguration(incomeRoot, true);
  const artifact = await buildCurrentBridge(incomeRoot);
  const client = await mutationClient();
  const deployment = await deployConfiguration(client, artifact.configuration);
  const matching = await rematchPromotedBatches(client);
  const ingredientReconciliation = await client.request("/internal/ingredient-gaps/reconcile", { method: "POST" });
  result = {
    ok: true,
    configurationId: artifact.configuration.id,
    configurationActivated: deployment.active === true,
    rematched: matching.ok === true,
    releasePublicationRequired: true,
    deployment,
    matching,
    ingredientReconciliation,
  };
} else if (command === "config" && subcommand === "archives") {
  result = await (await mutationClient()).request("/internal/configurations/archives");
} else if (command === "config" && subcommand === "archive") {
  const configurationId = arguments_[0];
  if (!configurationId) throw new Error("tc config archive requires a configuration id");
  result = await (await mutationClient()).request(`/internal/configurations/${encodeURIComponent(configurationId)}/archive`, { method: "POST" });
} else if (command === "config" && subcommand === "compact") {
  const configurationId = arguments_[0];
  if (!configurationId) throw new Error("tc config compact requires a configuration id");
  result = await (await mutationClient()).request(`/internal/configurations/${encodeURIComponent(configurationId)}/compact`, { method: "POST", acceptStatuses: [409] });
} else if (command === "schedules" && subcommand === "check") {
  result = await checkScheduleAuthority(platformRoot);
} else if (command === "schedules" && subcommand === "deploy") {
  const document = await readScheduleAuthority(platformRoot);
  result = await (await mutationClient()).request("/internal/schedules/sync", { method: "PUT", json: document });
} else if (command === "promotion" && subcommand === "sync") {
  const document = await localPromotionCalendarDocument();
  result = await (await mutationClient()).request("/internal/promotions/calendars/sync", { method: "PUT", json: document });
} else if (command === "promotion" && subcommand === "status") {
  result = await (await mutationClient()).request("/internal/promotions/status");
} else if (command === "promotion" && subcommand === "reconcile") {
  result = await (await mutationClient()).request("/internal/promotions/reconcile", { method: "POST" });
} else if (command === "promotion" && subcommand === "due") {
  const lane = arguments_[0];
  if (lane && lane !== "headless" && lane !== "browser") throw new Error("tc promotion due accepts only headless or browser");
  result = await (await mutationClient()).request(`/internal/promotions/requests/due${lane ? `?lane=${lane}` : ""}`);
} else if (command === "promotion" && subcommand === "claim") {
  const [lane, owner = `pc-${process.env.COMPUTERNAME ?? "local"}`] = arguments_;
  if (lane !== "headless" && lane !== "browser") throw new Error("tc promotion claim requires headless|browser [owner]");
  result = await (await mutationClient()).request("/internal/promotions/requests/claim", { json: {
    lane, owner, observedAt: new Date().toISOString(), leaseMinutes: lane === "browser" ? 180 : 60, limit: 20,
  } });
} else if (command === "promotion" && subcommand === "complete") {
  const [status, ...requestIds] = arguments_;
  if ((status !== "completed" && status !== "failed") || requestIds.length === 0) throw new Error("tc promotion complete requires completed|failed and one or more request ids");
  const completedAt = new Date().toISOString();
  result = await (await mutationClient()).request("/internal/promotions/requests/complete", { json: {
    requestIds, status, completedAt, result: { executor: "pc", completedAt },
    ...(status === "failed" ? { error: "local promotion-boundary execution failed" } : {}),
  } });
} else if (command === "transition" && subcommand === "readiness") {
  result = await (await mutationClient()).request("/internal/transitions/readiness");
} else if (command === "transition" && subcommand === "retire") {
  const job = arguments_[0];
  if (!job) throw new Error("tc transition retire requires a schedule id");
  result = await (await mutationClient()).request(`/internal/transitions/${encodeURIComponent(job)}/retire`, { method: "POST", acceptStatuses: [409] });
} else if (command === "control-plane" && subcommand === "prove") {
  result = await (await mutationClient()).request("/internal/control-plane/prove", { method: "POST", acceptStatuses: [422] });
} else if (command === "agents" && subcommand === "check") {
  result = await checkAgentRegistry(platformRoot);
} else if (command === "agents" && subcommand === "deploy") {
  await checkAgentRegistry(platformRoot);
  result = await (await mutationClient()).request("/internal/agents/sync", { method: "PUT", json: await readAgentRegistry(platformRoot) });
} else if (command === "agent" && subcommand === "evaluation") {
  const file = arguments_[0];
  if (!file) throw new Error("tc agent evaluation requires an evaluation JSON file");
  result = await (await mutationClient()).request("/internal/agent-evaluations", { json: JSON.parse(await readFile(cliPath(file), "utf8")), acceptStatuses: [422] });
} else if (command === "agent" && subcommand === "evaluation-status") {
  const [agentId, outputFile] = arguments_;
  if (!agentId) throw new Error("tc agent evaluation-status requires an agent id");
  result = await (await mutationClient()).request(`/internal/agents/${encodeURIComponent(agentId)}/evaluation-status`);
  if (outputFile) await writeJson(cliPath(outputFile), result);
} else if (command === "agent" && subcommand === "claim") {
  const [agentId, outputFile] = arguments_;
  if (!agentId || !outputFile) throw new Error("tc agent claim requires an agent id and output metadata file");
  const registry = await readAgentRegistry(platformRoot);
  const agent = registry.agents.find((entry) => entry.id === agentId);
  if (!agent) throw new Error(`unknown agent ${agentId}`);
  const claimed = await (await mutationClient()).request("/internal/agent-work-items/claim", { json: {
    agentId,
    adapterVersion: "phase2-v1",
    inputContract: agent.inputContracts[0],
    leaseSeconds: 900,
  } }) as { item?: Record<string, unknown> | null };
  await writeJson(cliPath(outputFile), claimed);
  result = { ok: true, claimed: Boolean(claimed.item), outputFile: cliPath(outputFile) };
} else if (command === "agent" && subcommand === "authorize") {
  const [agentId, metadataFile, estimated = "500000", outputFile] = arguments_;
  if (!agentId || !metadataFile) throw new Error("tc agent authorize requires an agent id and claim metadata file");
  const claim = JSON.parse(await readFile(cliPath(metadataFile), "utf8")) as { item?: { id?: string } };
  if (!claim.item?.id) throw new Error("claim metadata does not contain a work item");
  result = await (await mutationClient()).request(`/internal/agents/${encodeURIComponent(agentId)}/authorize?estimatedCostMicrousd=${encodeURIComponent(estimated)}&workItemId=${encodeURIComponent(claim.item.id)}`);
  if (outputFile) await writeJson(cliPath(outputFile), result);
} else if (command === "agent" && subcommand === "complete") {
  const [metadataFile, outputFile] = arguments_;
  if (!metadataFile || !outputFile) throw new Error("tc agent complete requires claim metadata and agent output files");
  const claim = JSON.parse(await readFile(cliPath(metadataFile), "utf8")) as { item?: { id?: string; lease_id?: string; lease_generation?: number } };
  const runnerOutput = JSON.parse(await readFile(cliPath(outputFile), "utf8")) as { finalOutput?: unknown };
  if (!claim.item?.id || !claim.item.lease_id || !claim.item.lease_generation) throw new Error("claim metadata is incomplete");
  let output = runnerOutput.finalOutput;
  if (typeof output === "string") {
    try { output = JSON.parse(output); } catch { output = { text: output }; }
  }
  result = await (await mutationClient()).request(`/internal/agent-work-items/${encodeURIComponent(claim.item.id)}/complete`, { json: {
    leaseId: claim.item.lease_id,
    leaseGeneration: claim.item.lease_generation,
    output,
  } });
} else if (command === "agent" && subcommand === "fail") {
  const [metadataFile, reason = "agent execution failed before producing a valid output"] = arguments_;
  if (!metadataFile) throw new Error("tc agent fail requires claim metadata");
  const claim = JSON.parse(await readFile(cliPath(metadataFile), "utf8")) as { item?: { id?: string; lease_id?: string; lease_generation?: number } };
  if (!claim.item?.id || !claim.item.lease_id || !claim.item.lease_generation) throw new Error("claim metadata is incomplete");
  result = await (await mutationClient()).request(`/internal/agent-work-items/${encodeURIComponent(claim.item.id)}/fail`, { json: {
    leaseId: claim.item.lease_id,
    leaseGeneration: claim.item.lease_generation,
    reason,
    retryable: true,
  } });
} else if (command === "backup" && subcommand === "trigger") {
  result = await (await mutationClient()).request(`/internal/backups/trigger${arguments_.includes("--replica") ? "?replica=1" : ""}`, { method: "POST" });
} else if (command === "backup" && subcommand === "checkpoint") {
  result = await (await mutationClient()).request("/internal/backups/checkpoint", { method: "POST" });
} else if (command === "restore" && subcommand === "record") {
  const file = arguments_[0];
  if (!file) throw new Error("tc restore record requires a JSON evidence file");
  result = await (await mutationClient()).request("/internal/restore-drills", { json: JSON.parse(await readFile(cliPath(file), "utf8")) });
} else if (command === "restore" && subcommand === "show") {
  result = await (await mutationClient()).request("/internal/restore-drills");
} else if (command === "restore" && subcommand === "trigger") {
  result = await (await mutationClient()).request(`/internal/restore-drills/trigger${arguments_.includes("--force") ? "?force=1" : ""}`, { method: "POST" });
} else if (command === "restore" && subcommand === "cleanup") {
  const [file] = arguments_;
  if (!file) throw new Error("tc restore cleanup requires a JSON cleanup-evidence file");
  result = await (await mutationClient()).request("/internal/restore-drills/cleanup", { json: JSON.parse(await readFile(cliPath(file), "utf8")) });
} else if (command === "archive" && subcommand === "plan") {
  // Keep one full extra day behind the API's 24-hour ingestion window.
  const cutoffAt = arguments_.find((value: string) => !value.startsWith("--")) ?? new Date(Date.now() - 2 * 24 * 60 * 60 * 1000).toISOString();
  result = await (await mutationClient()).request("/internal/archival/plan", { json: { cutoffAt, dryRun: !arguments_.includes("--execute"), maximumRows: 10000 }, acceptStatuses: [409, 422] });
} else if (command === "archive" && subcommand === "forecast") {
  result = await (await mutationClient()).request("/internal/archival/forecast/run", { method: "POST" });
} else if (command === "archive" && subcommand === "export") {
  const [manifestId, outputFile] = arguments_;
  if (!manifestId || !outputFile) throw new Error("tc archive export requires a manifest id and output JSON file");
  const exported = await (await mutationClient()).request(`/internal/archival/${encodeURIComponent(manifestId)}/export`);
  await writeJson(cliPath(outputFile), exported);
  result = { ok: true, manifestId, outputFile: cliPath(outputFile), rows: Array.isArray(exported.rows) ? exported.rows.length : 0 };
} else if (command === "archive" && subcommand === "upload") {
  const [manifestId, parquetFile] = arguments_;
  if (!manifestId || !parquetFile) throw new Error("tc archive upload requires a manifest id and Parquet file");
  result = await (await mutationClient()).request(`/internal/archival/${encodeURIComponent(manifestId)}/parquet`, { method: "PUT", body: new Uint8Array(await readFile(cliPath(parquetFile))), headers: { "content-type": "application/vnd.apache.parquet" } });
} else if (command === "archive" && subcommand === "execute") {
  const [manifestId, archiveSha256] = arguments_;
  if (!manifestId || !archiveSha256) throw new Error("tc archive execute requires a manifest id and verified archive SHA-256");
  result = await (await mutationClient()).request(`/internal/archival/${encodeURIComponent(manifestId)}/execute`, { json: { archiveSha256 } });
} else if (command === "storage" && subcommand === "migrate-releases") {
  const client = await mutationClient();
  const inventory = await client.request("/internal/storage/releases") as unknown as {
    releases: Array<{ id: string; root_hash: string | null }>;
  };
  const backfilled: Array<Record<string, unknown>> = [];
  for (const release of inventory.releases.filter((item) => !item.root_hash)) {
    backfilled.push(await client.request(`/internal/storage/backfill-release/${encodeURIComponent(release.id)}`, { method: "POST" }) as Record<string, unknown>);
  }
  const compacted: Array<Record<string, unknown>> = [];
  while (true) {
    const page = await client.request("/internal/storage/compact-releases", { method: "POST" }) as unknown as {
      compacted: Array<Record<string, unknown>>;
    };
    compacted.push(...page.compacted);
    if (page.compacted.length === 0) break;
  }
  result = { ok: true, releases: inventory.releases.length, backfilled: backfilled.length, compacted };
} else if (command === "storage" && subcommand === "gc-plan") {
  const graceDays = Number(arguments_.find((value: string) => /^\d+$/.test(value)) ?? "7");
  result = await (await mutationClient()).request("/internal/storage/gc/plan", {
    json: { graceDays, maximumObjects: 500, execute: arguments_.includes("--execute") }, acceptStatuses: [422],
  });
} else if (command === "storage" && subcommand === "gc-sweep") {
  const runId = arguments_.find((value: string) => !value.startsWith("--"));
  if (!runId) throw new Error("tc storage gc-sweep requires a run id");
  result = await (await mutationClient()).request(`/internal/storage/gc/${encodeURIComponent(runId)}/sweep`, {
    json: { execute: arguments_.includes("--execute") }, acceptStatuses: [409],
  });
} else if (command === "cleanup" && subcommand === "plan") {
  result = await (await mutationClient()).request("/internal/canonical-cleanup/plan", { json: { dryRun: !arguments_.includes("--execute"), maximumRows: 10000 }, acceptStatuses: [422] });
} else if (command === "cleanup" && subcommand === "index") {
  const client = await mutationClient();
  let cursor = "";
  let indexed = 0;
  let secondPass = false;
  while (true) {
    const page = await client.request(`/internal/canonical-cleanup/index?after=${encodeURIComponent(cursor)}`, { method: "POST" }) as unknown as { indexed: number; nextCursor: string };
    indexed += page.indexed;
    if (page.indexed > 0) { cursor = page.nextCursor; continue; }
    if (!secondPass && cursor) { cursor = ""; secondPass = true; continue; }
    break;
  }
  let canonicalCursor = "";
  let indexedCanonicalGroups = 0;
  while (true) {
    const page = await client.request(`/internal/canonical-cleanup/canonicals?after=${encodeURIComponent(canonicalCursor)}`, { method: "POST" }) as unknown as { indexed: number; nextCursor: string };
    indexedCanonicalGroups += page.indexed;
    if (page.indexed === 0) break;
    canonicalCursor = page.nextCursor;
  }
  result = { ok: true, indexed, indexedCanonicalGroups };
} else if (command === "cleanup" && subcommand === "export") {
  const [runId, outputFile] = arguments_;
  if (!runId || !outputFile) throw new Error("tc cleanup export requires a run id and output JSON file");
  const exported = await (await mutationClient()).request(`/internal/canonical-cleanup/${encodeURIComponent(runId)}/export`);
  await writeJson(cliPath(outputFile), exported);
  result = { ok: true, runId, outputFile: cliPath(outputFile), rows: Array.isArray(exported.rows) ? exported.rows.length : 0 };
} else if (command === "cleanup" && subcommand === "upload") {
  const [runId, parquetFile] = arguments_;
  if (!runId || !parquetFile) throw new Error("tc cleanup upload requires a run id and Parquet file");
  result = await (await mutationClient()).request(`/internal/canonical-cleanup/${encodeURIComponent(runId)}/parquet`, { method: "PUT", body: new Uint8Array(await readFile(cliPath(parquetFile))), headers: { "content-type": "application/vnd.apache.parquet" } });
} else if (command === "cleanup" && subcommand === "execute") {
  const [runId, archiveSha256] = arguments_;
  if (!runId || !archiveSha256) throw new Error("tc cleanup execute requires a run id and verified archive SHA-256");
  result = await (await mutationClient()).request(`/internal/canonical-cleanup/${encodeURIComponent(runId)}/execute`, { json: { archiveSha256 } });
} else if (command === "maintenance" && subcommand === "architecture") {
  const [action = "status", value] = arguments_;
  const client = await mutationClient();
  if (action === "status") result = await client.request("/internal/maintenance/architecture");
  else {
    const apiAction = ({ reasons: "release-reasons", entities: "product-entities", suggestions: "entity-suggestions", "build-details": "recipe-detail-build", "compact-details": "recipe-detail-compact" } as Record<string, string>)[action];
    if (!apiAction) throw new Error("tc maintenance architecture requires status, reasons, entities, suggestions, build-details, or compact-details");
    if (["build-details", "compact-details"].includes(action) && !value) throw new Error(`${action} requires a release id`);
    result = await client.request("/internal/maintenance/architecture", { json: { action: apiAction, ...(value ? { releaseId: value } : {}), limit: 200 } });
  }
} else if (command === "content" && subcommand === "show") {
  result = await (await mutationClient()).request("/internal/content-batches");
} else if (command === "content" && subcommand === "create") {
  const file = arguments_[0];
  if (!file) throw new Error("tc content create requires a batch JSON file");
  result = await (await mutationClient()).request("/internal/content-batches", { json: JSON.parse(await readFile(cliPath(file), "utf8")) });
} else if (command === "content" && subcommand === "items") {
  const [batchId, file] = arguments_;
  if (!batchId || !file) throw new Error("tc content items requires a batch id and items JSON file");
  result = await (await mutationClient()).request(`/internal/content-batches/${encodeURIComponent(batchId)}/items`, { json: JSON.parse(await readFile(cliPath(file), "utf8")) });
} else if (command === "content" && subcommand === "audit") {
  const [batchId, file] = arguments_;
  if (!batchId || !file) throw new Error("tc content audit requires a batch id and audit JSON file");
  result = await (await mutationClient()).request(`/internal/content-batches/${encodeURIComponent(batchId)}/audit`, { json: JSON.parse(await readFile(cliPath(file), "utf8")), acceptStatuses: [422] });
} else if (command === "content" && subcommand === "promote") {
  const batchId = arguments_[0];
  if (!batchId) throw new Error("tc content promote requires a batch id");
  result = await (await mutationClient()).request(`/internal/content-batches/${encodeURIComponent(batchId)}/promote`, { method: "POST", acceptStatuses: [422] });
} else if (command === "content" && subcommand === "promote-ready") {
  const client = await mutationClient();
  const since = arguments_[0];
  const sinceMillis = since ? Date.parse(since) : Number.NEGATIVE_INFINITY;
  if (since && !Number.isFinite(sinceMillis)) throw new Error("tc content promote-ready optional since value must be an ISO timestamp");
  const listed = await client.request("/internal/content-batches") as { batches?: Array<{ id?: string; kind?: string; status?: string; created_at?: string }> };
  const audited = (listed.batches ?? []).filter((batch) =>
    batch.kind === "recipe-pack" && batch.status === "audited" && batch.id
    && (!since || Date.parse(`${batch.created_at ?? ""}Z`) >= sinceMillis));
  const promotions = [];
  for (const batch of audited) {
    promotions.push(await client.request(`/internal/content-batches/${encodeURIComponent(batch.id!)}/promote`, { method: "POST", acceptStatuses: [422] }));
  }
  const rejected = promotions.filter((promotion) => promotion.ok === false);
  if (rejected.length > 0) throw new Error(`${rejected.length} audited recipe content batch${rejected.length === 1 ? "" : "es"} failed deterministic promotion`);
  result = { ok: rejected.length === 0, since: since ?? null, examined: audited.length, promoted: promotions.filter((promotion) => promotion.ok).length, rejected: rejected.length, promotions };
} else if (command === "evidence" && subcommand === "record") {
  const file = arguments_[0];
  if (!file) throw new Error("tc evidence record requires a JSON evidence file");
  result = await (await mutationClient()).request("/internal/evidence-gates", { json: JSON.parse(await readFile(cliPath(file), "utf8")) });
} else if (command === "evidence" && subcommand === "show") {
  const gate = arguments_[0];
  result = await (await mutationClient()).request(`/internal/evidence-gates${gate ? `?gate=${encodeURIComponent(gate)}` : ""}`);
} else if (command === "evidence" && subcommand === "accrue") {
  const observedAt = new Date().toISOString();
  const edgeUrl = new URL("/api/v2/releases/current", process.env.TC_EDGE_ORIGIN ?? "https://www.thriftycrew.com");
  edgeUrl.searchParams.set("milestone_probe", observedAt);
  const edgeResponse = await fetch(edgeUrl, { headers: { accept: "application/json", "cache-control": "no-cache" } });
  let edgeReleaseId: string | null = null;
  try {
    const edgeBody = await edgeResponse.json() as { releaseId?: unknown };
    edgeReleaseId = typeof edgeBody.releaseId === "string" ? edgeBody.releaseId : null;
  } catch {
    // The API records a content-type/release mismatch without laundering a non-JSON edge response.
  }
  result = await (await mutationClient()).request("/internal/evidence-gates/accrue", { json: { edgeProof: {
    url: edgeUrl.toString(),
    httpStatus: edgeResponse.status,
    contentType: edgeResponse.headers.get("content-type") ?? "",
    releaseId: edgeReleaseId,
    observedAt,
  } }, acceptStatuses: [422] });
} else if (command === "entitlement" && subcommand === "record") {
  const file = arguments_[0];
  if (!file) throw new Error("tc entitlement record requires a JSON evidence file");
  result = await (await mutationClient()).request("/internal/entitlement-verifications", { json: JSON.parse(await readFile(cliPath(file), "utf8")) });
} else if (command === "entitlement" && subcommand === "show") {
  result = await (await mutationClient()).request("/internal/entitlement-verifications");
} else if (command === "canary" && subcommand === "record") {
  const file = arguments_[0];
  if (!file) throw new Error("tc canary record requires a login-canary probe JSON file");
  result = await (await mutationClient()).request("/internal/login-canary-probes", { json: JSON.parse(await readFile(cliPath(file), "utf8")) });
} else if (command === "drill" && subcommand === "release-freeze") {
  result = await releaseFreezeDrill();
} else if (command === "drill" && subcommand === "ghost-clobber") {
  const requestedRelease = arguments_[0];
  const status = requestedRelease ? null : await publicGet("/api/v2/status") as { currentRelease?: { id?: string } };
  const releaseId = requestedRelease ?? status?.currentRelease?.id;
  if (!releaseId) throw new Error("no published release is available for the Ghost clobber drill");
  result = await (await mutationClient()).request(`/internal/releases/${releaseId}/drill-ghost-clobber`, { method: "POST", acceptStatuses: [422] });
} else if (command === "drill" && subcommand === "chaos") {
  const kind = arguments_[0];
  if (!kind) throw new Error("tc drill chaos requires run-interruption, wrong-basis, or referenced-commodity-delete");
  result = await (await mutationClient()).request(`/internal/drills/${encodeURIComponent(kind)}`, { method: "POST", acceptStatuses: [422] });
} else if (command === "drill" && subcommand === "stale-capture") {
  const file = arguments_[0] ?? path.join(platformRoot, "fixtures", "chaos", "stale-browser-capture.json");
  const bytes = new Uint8Array(await readFile(cliPath(file)));
  const artifact = directCaptureArtifactSchema.parse(JSON.parse(new TextDecoder().decode(bytes).replace(/^\uFEFF/, "")));
  if (!artifact.sourceId.endsWith("-browser") || Date.parse(artifact.capturedTo) > Date.now() - 15 * 24 * 60 * 60 * 1000) {
    throw new Error("stale-capture drill requires a browser artifact older than every browser source freshness window");
  }
  const client = await mutationClient();
  const ingestion = await ingestDirectCapture(client, artifact, bytes);
  const passed = ingestion.ok === false && ingestion.status === "rejected";
  const observedAt = new Date().toISOString();
  const evidence = { artifact: path.basename(file), ingestion, expected: "batch-freshness rejection and no promotion" };
  const recorded = await client.request("/internal/evidence-gates", { json: {
    id: `evidence_stale_capture_${observedAt.slice(0, 10).replaceAll("-", "")}`,
    gate: "chaos-drill",
    periodKey: `stale-capture-${observedAt.slice(0, 10)}`,
    sourceRef: String(ingestion.batchId),
    status: passed ? "pass" : "fail",
    observedAt,
    evidence,
  }, acceptStatuses: [422] });
  result = { ok: passed, ingestion, evidenceEventId: recorded.eventId };
} else if (command === "job" && subcommand === "start") {
  const job = arguments_[0];
  if (!job) throw new Error("tc job start requires a job id");
  const runId = githubRunId(job);
  const now = new Date().toISOString();
  const started = await (await mutationClient()).request("/internal/job-runs", { json: {
    id: runId,
    job,
    triggerKind: process.env.GITHUB_RUN_ID ? "schedule" : "operator",
    scheduledFor: process.env.TC_SCHEDULED_FOR ?? now,
    startedAt: now,
    executorRunId: process.env.GITHUB_SERVER_URL && process.env.GITHUB_REPOSITORY && process.env.GITHUB_RUN_ID
      ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}`
      : runId,
    ...agentJobRunFields(process.env),
    input: { reason: process.env.TC_RECOVERY_REASON ?? "scheduled operation", ...(process.env.TC_AGENT_WORK_ITEM_ID ? { workItemId: process.env.TC_AGENT_WORK_ITEM_ID } : {}) },
  }, acceptStatuses: [409] });
  result = started;
  if (started.httpStatus !== 409 && process.env.TC_JOB_LEASE_FILE) await writeJson(process.env.TC_JOB_LEASE_FILE, started);
  if (started.httpStatus === 409) process.exitCode = 75;
} else if (command === "job" && subcommand === "github-runs") {
  const limit = arguments_[0] ?? "5";
  if (!/^([1-9]|10)$/.test(limit)) throw new Error("tc job github-runs limit must be from 1 through 10");
  result = await (await mutationClient()).request(`/internal/jobs/github-runs?limit=${limit}`);
} else if (command === "job" && subcommand === "reconcile") {
  const [runId, requestedStatus, ...reasonParts] = arguments_;
  if (!runId || !requestedStatus || !["completed", "failed", "timed_out", "cancelled"].includes(requestedStatus)) {
    throw new Error("tc job reconcile requires a run id and completed|failed|timed_out|cancelled");
  }
  const finishedAt = new Date().toISOString();
  result = await (await mutationClient()).request(`/internal/job-runs/${encodeURIComponent(runId)}`, { method: "PATCH", json: {
    status: requestedStatus,
    heartbeatAt: finishedAt,
    finishedAt,
    usage: { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, costMicrousd: 0 },
    stats: { operatorReconciliation: true, reason: reasonParts.join(" ") || "external executor truth reconciled" },
    ...(["failed", "timed_out"].includes(requestedStatus) ? { error: reasonParts.join(" ") || `external executor ended ${requestedStatus}` } : {}),
  } });
} else if (command === "job" && subcommand === "dispatch") {
  const job = arguments_[0];
  if (!job) throw new Error("tc job dispatch requires a job id");
  const reason = arguments_.slice(1).join(" ") || "operator recovery drill";
  result = await (await mutationClient()).request(`/internal/jobs/${encodeURIComponent(job)}/dispatch`, { json: {
    idempotencyKey: `operator-${job}-${new Date().toISOString().replaceAll(/[^0-9]/g, "").slice(0, 14)}`,
    reason,
    ref: "main",
  } });
} else if (command === "job" && subcommand === "finish") {
  const job = arguments_[0];
  if (!job) throw new Error("tc job finish requires a job id");
  const requested = arguments_[1] ?? "completed";
  const status = requested === "success" ? "completed" : requested === "completed" ? "completed" : "failed";
  const now = new Date().toISOString();
  const usage = process.env.TC_AGENT_USAGE_JSON ? JSON.parse(process.env.TC_AGENT_USAGE_JSON) as Record<string, number> : {};
  result = await (await mutationClient()).request(`/internal/job-runs/${githubRunId(job)}`, { method: "PATCH", json: {
    status,
    heartbeatAt: now,
    finishedAt: now,
    usage: {
      inputTokens: usage.inputTokens ?? 0,
      outputTokens: usage.outputTokens ?? 0,
      cacheReadTokens: usage.cacheReadTokens ?? 0,
      cacheWriteTokens: usage.cacheWriteTokens ?? 0,
      costMicrousd: usage.costMicrousd ?? 0,
    },
    stats: { executorStatus: requested, executionPlane: process.env.GITHUB_RUN_ID ? "github-actions" : "pc" },
    ...(status === "failed" ? { error: `${process.env.GITHUB_RUN_ID ? "GitHub Actions" : "PC"} job execution ended with ${requested}` } : {}),
  } });
} else if (command === "ghost" && subcommand === "reconcile") {
  const requestedRelease = arguments_[0];
    const status = requestedRelease ? null : await publicGet("/api/v2/status") as { currentRelease?: { id?: string } };
    const releaseId = requestedRelease ?? status?.currentRelease?.id;
  if (!releaseId) throw new Error("no published release is available for Ghost reconciliation");
  result = await (await mutationClient()).request(`/internal/releases/${releaseId}/reconcile-ghost`, { method: "POST" });
} else if (command === "run" && subcommand === "daily" && arguments_.includes("--dry")) {
  const artifact = await buildCurrentBridge(incomeRoot);
  result = { ok: true, dryRun: true, audit: artifact.audit, releaseInputs: artifact.stores.length };
} else if (command === "parity") {
  const artifact = await buildCurrentBridge(incomeRoot);
  result = { ok: artifact.audit.incompleteRecipes === 0 && artifact.audit.uncategorized.length === 0 && artifact.audit.multiplyCategorized.length === 0, audit: artifact.audit };
} else if (command === "recipes" && subcommand === "gaps") {
  const published = await publicGet("/api/v2/recipes") as {
    releaseId?: string;
    payload?: { recipes?: Array<{ slug: string; name: string; status: string; missingIngredients?: string[] }> };
  };
  const recipes = published.payload?.recipes ?? [];
  const incomplete = recipes.filter((recipe) => recipe.status !== "complete");
  const held = incomplete.filter((recipe) => recipe.status === "held");
  const unresolved = incomplete.filter((recipe) => recipe.status !== "held");
  const dependencyCounts = new Map<string, number>();
  for (const recipe of incomplete) {
    for (const ingredient of recipe.missingIngredients ?? []) {
      dependencyCounts.set(ingredient, (dependencyCounts.get(ingredient) ?? 0) + 1);
    }
  }
  result = {
    ok: incomplete.length === 0,
    releaseId: published.releaseId ?? null,
    totals: {
      recipes: recipes.length,
      complete: recipes.length - incomplete.length,
      held: held.length,
      incomplete: unresolved.length,
    },
    dependencies: [...dependencyCounts].map(([ingredient, affectedRecipes]) => ({ ingredient, affectedRecipes }))
      .sort((left, right) => right.affectedRecipes - left.affectedRecipes || left.ingredient.localeCompare(right.ingredient)),
    recipes: incomplete.map((recipe) => ({
      slug: recipe.slug,
      name: recipe.name,
      status: recipe.status,
      missingIngredients: recipe.missingIngredients ?? [],
    })),
  };
} else if (command === "release" && subcommand === "reject") {
  const releaseId = arguments_[0];
  if (!releaseId) throw new Error("tc release reject requires a release id");
  result = await (await mutationClient()).request(`/internal/releases/${encodeURIComponent(releaseId)}/reject`, { method: "POST" });
} else if (command === "engine" && subcommand === "parity") {
  const requestedMode = arguments_[0] ?? "legacy";
  if (!(["legacy", "direct", "all"] as const).includes(requestedMode as "legacy" | "direct" | "all")) throw new Error("tc engine parity mode must be legacy, direct, or all");
  const client = await mutationClient();
  const snapshot = await loadEngineSnapshot(client, requestedMode as "legacy" | "direct" | "all", "parity");
  const report = buildNativeParityReport(snapshot);
  result = await client.request("/internal/engine/parity", { json: report, acceptStatuses: [422] });
} else if (command === "engine" && subcommand === "snapshot-identity") {
  result = await (await mutationClient()).request("/internal/engine/snapshot-identity?mode=direct");
} else if (command === "engine" && (subcommand === "build-native" || subcommand === "publish-native")) {
  const operationStartedAt = performance.now();
  const performanceProfile: Record<string, number> = {};
  const client = await mutationClient();
  // A configuration can change while a time-windowed, superseded batch remains the
  // effective input. Bind every effective batch to the active matcher immediately
  // before publication so the immutable snapshot can never select an unbound input.
  if (subcommand === "publish-native") await rematchPromotedBatches(client);
  let stageStartedAt = performance.now();
  const identity = await client.request("/internal/engine/snapshot-identity?mode=direct") as unknown as Pick<NativeEngineSnapshot, "mode" | "observedAt" | "configurationId" | "inputHash" | "inputBatchIds" | "contentBatchIds" | "contentRecipeHash">;
  performanceProfile.snapshotIdentityMs = Math.round(performance.now() - stageStartedAt);
  stageStartedAt = performance.now();
  const catalog = await loadNativeReleaseCatalog(incomeRoot);
  const expected = await nativeReleaseIdentity(identity, catalog);
  performanceProfile.localCatalogAndIdentityMs = Math.round(performance.now() - stageStartedAt);
  if (subcommand === "publish-native") {
    stageStartedAt = performance.now();
    const existing = await client.request(`/internal/releases/${encodeURIComponent(expected.releaseId)}`, { acceptStatuses: [404] }) as {
      found?: boolean; release?: { input_hash?: string; state?: string };
    };
    performanceProfile.existingReleasePreflightMs = Math.round(performance.now() - stageStartedAt);
    if (existing.found && existing.release?.state === "published") {
      if (existing.release.input_hash !== expected.inputHash) throw new Error(`native release ${expected.releaseId} has a conflicting input hash`);
      performanceProfile.totalMs = Math.round(performance.now() - operationStartedAt);
      result = { ok: true, releaseId: expected.releaseId, inputHash: expected.inputHash, state: "published", idempotent: true, reused: true, performance: performanceProfile };
    }
  }
  if (result === undefined) {
    stageStartedAt = performance.now();
    const [snapshot, previousGraph] = await Promise.all([
      loadEngineSnapshot(client, "direct"),
      loadCurrentReleaseGraph(client),
    ]);
    performanceProfile.snapshotFetchMs = Math.round(performance.now() - stageStartedAt);
    performanceProfile.snapshotResponseBytes = snapshot.transportBytes ?? new TextEncoder().encode(stableJson(snapshot)).byteLength;
    stageStartedAt = performance.now();
    const artifact = await buildNativeRelease(incomeRoot, snapshot, catalog, previousGraph);
    performanceProfile.nativeBuildMs = Math.round(performance.now() - stageStartedAt);
    const outputArgument = arguments_.find((value: string) => value.endsWith(".json"));
    if (outputArgument) await writeJson(cliPath(outputArgument), artifact);
    if (Number(artifact.audit.top5Entries) !== 20 || Number(artifact.audit.rotationEntries) !== 20) {
      throw new Error(`native release preflight requires exactly 20 complete ranked recipes; got ${String(artifact.audit.top5Entries)}`);
    }
    if (subcommand === "build-native") {
      performanceProfile.totalMs = Math.round(performance.now() - operationStartedAt);
      result = { ok: true, releaseId: artifact.releaseId, inputHash: artifact.inputHash, outputFile: outputArgument ? cliPath(outputArgument) : null, audit: artifact.audit, performance: performanceProfile };
    } else {
      stageStartedAt = performance.now();
      const publication = await publishNativeRelease(client, artifact);
      performanceProfile.publishMs = Math.round(performance.now() - stageStartedAt);
      performanceProfile.totalMs = Math.round(performance.now() - operationStartedAt);
      result = { ...publication, performance: performanceProfile };
      await client.request("/internal/engine/measurements", { json: {
        releaseId: artifact.releaseId,
        inputHash: artifact.inputHash,
        encoding: snapshot.transportEncoding ?? "json-rows-v1",
        matchedCandidates: snapshot.candidates.length,
        unmatchedCandidates: snapshot.rawCandidates?.length ?? 0,
        responseBytes: performanceProfile.snapshotResponseBytes,
        snapshotFetchMs: performanceProfile.snapshotFetchMs,
        nativeBuildMs: performanceProfile.nativeBuildMs,
        publishMs: performanceProfile.publishMs,
        totalMs: performanceProfile.totalMs,
      } });
    }
  }
} else if (command === "replay") {
  const artifact = await buildCurrentBridge(incomeRoot);
  result = await replayCurrentArtifact(await mutationClient(), artifact);
} else if (command === "capture" && subcommand === "metrics") {
  const requestedLimit = Number.parseInt(arguments_[0] ?? "25", 10);
  if (!Number.isFinite(requestedLimit) || requestedLimit < 1 || requestedLimit > 100) throw new Error("tc capture metrics limit must be between 1 and 100");
  result = await (await mutationClient()).request(`/internal/capture-metrics?limit=${requestedLimit}`);
} else if (command === "capture" && subcommand === "coordinator") {
  const [action, ...coordinatorArguments] = arguments_;
  const request = async (pathname: string, body: Record<string, unknown> = {}) => {
    const response = await captureControllerRequest(pathname, body, process.env, 5_000);
    if (!response) throw new Error("persistent capture controller is unavailable");
    return response;
  };
  if (action === "status") result = await request("/v1/coordinator/status");
  else if (action === "next") {
    const [owner, store, countText] = coordinatorArguments;
    if (!owner) throw new Error("tc capture coordinator next requires an executor owner");
    const count = countText === undefined ? 1 : Number.parseInt(countText, 10);
    if (!Number.isInteger(count) || count < 1 || count > 5) throw new Error("tc capture coordinator next count must be between 1 and 5");
    result = await request("/v1/work/next", { owner, count, ...(store ? { store } : {}) });
  } else if (action === "heartbeat") {
    const [owner, workId] = coordinatorArguments;
    if (!owner || !workId) throw new Error("tc capture coordinator heartbeat requires owner and work ID");
    result = await request("/v1/work/heartbeat", { owner, workId });
  } else if (action === "fail") {
    const [owner, workId, error = "capture executor failed"] = coordinatorArguments;
    if (!owner || !workId) throw new Error("tc capture coordinator fail requires owner and work ID");
    result = await request("/v1/work/fail", { owner, workId, error });
  } else if (action === "challenge") {
    const [store, reason = "retailer human-verification wall detected"] = coordinatorArguments;
    if (!store) throw new Error("tc capture coordinator challenge requires a store");
    result = await request("/v1/challenges/open", { store, detail: { reason }, notify: true });
  } else if (action === "resolve") {
    const [challengeId] = coordinatorArguments;
    if (!challengeId) throw new Error("tc capture coordinator resolve requires a challenge ID after a fresh canary pass");
    result = await request(`/v1/challenges/${encodeURIComponent(challengeId)}/resolve`, { canaryPassed: true });
  } else throw new Error("tc capture coordinator requires status, next, heartbeat, fail, challenge, or resolve");
} else if (command === "capture" && subcommand === "session") {
  const [action, ...sessionArguments] = arguments_;
  if (action === "worklist") {
    const [pullOrderFile, rescueFile, outputFile] = sessionArguments;
    if (!pullOrderFile || !rescueFile || !outputFile) throw new Error("tc capture session worklist requires pull-order, rescue (or -), and output files");
    result = await buildCaptureSessionWorklist(cliPath(pullOrderFile), rescueFile === "-" ? null : cliPath(rescueFile), cliPath(outputFile));
  } else if (action === "init") {
    const [store, worklistFile, directory, startedAt] = sessionArguments;
    if (!store || !worklistFile || !directory) throw new Error("tc capture session init requires store, worklist file, and session directory");
    const session = await initializeCaptureSession(store, cliPath(worklistFile), cliPath(directory), startedAt);
    result = {
      ok: true,
      sessionId: session.sessionId,
      store: session.store,
      sourceId: session.sourceId,
      startedAt: session.startedAt,
      expectedTerms: session.worklist.length,
      worklistHash: session.worklistHash,
      sessionDirectory: cliPath(directory),
    };
  } else if (action === "append") {
    const [directory, chunkFile] = sessionArguments;
    if (!directory || !chunkFile) throw new Error("tc capture session append requires session directory and chunk JSON");
    const controlled = await captureControllerRequest("/v1/sessions/commit-file", { directory: cliPath(directory), chunkFile: cliPath(chunkFile) }, process.env, 30_000);
    result = controlled ?? { ok: true, ...(await appendCaptureChunk(cliPath(directory), cliPath(chunkFile))), controllerFallback: true };
  } else if (action === "evidence") {
    const [directory, evidenceFile, kind = "screenshot"] = sessionArguments;
    if (!directory || !evidenceFile) throw new Error("tc capture session evidence requires a session directory and evidence file");
    const controlled = await captureControllerRequest("/v1/sessions/evidence-file", { directory: cliPath(directory), evidenceFile: cliPath(evidenceFile), kind }, process.env, 30_000);
    result = controlled ?? { ...(await retainCaptureSessionEvidence(cliPath(directory), cliPath(evidenceFile), kind)), controllerFallback: true };
  } else if (action === "finalize") {
    const [directory, projectedFile, manifestFile, finishedAt] = sessionArguments;
    if (!directory || !projectedFile || !manifestFile) throw new Error("tc capture session finalize requires session directory, projected capture output, and manifest output");
    const session = await finalizeCaptureSession(cliPath(directory), cliPath(projectedFile), cliPath(manifestFile), finishedAt);
    result = { ok: true, sessionId: session.sessionId, store: session.store, coverageMode: session.coverageMode, expectedTerms: session.expectedTerms, observations: session.terms.reduce((total, term) => total + term.rowCount, 0), outputFile: cliPath(projectedFile), manifestFile: cliPath(manifestFile) };
  } else if (action === "status") {
    const [directory] = sessionArguments;
    if (!directory) throw new Error("tc capture session status requires a session directory");
    result = await captureSessionStatus(cliPath(directory));
  } else if (action === "abandon") {
    const [directory, ...reasonParts] = sessionArguments;
    if (!directory || reasonParts.length === 0) throw new Error("tc capture session abandon requires a session directory and reason");
    result = await abandonCaptureSession(cliPath(directory), reasonParts.join(" "));
  } else if (action === "verification-plan") {
    const [directory, outputFile] = sessionArguments;
    if (!directory || !outputFile) throw new Error("tc capture session verification-plan requires a session directory and output JSON");
    result = await buildCaptureVerificationPlan(cliPath(directory), cliPath(outputFile));
  } else if (action === "refresh-plan") {
    const [store, outputFile, maxAgeInput = "7", limitInput = "500"] = sessionArguments;
    if (!store || !outputFile) throw new Error("tc capture session refresh-plan requires store and output JSON");
    const maxAgeDays = Number.parseInt(maxAgeInput, 10);
    const limit = Number.parseInt(limitInput, 10);
    if (!Number.isSafeInteger(maxAgeDays) || maxAgeDays < 1 || maxAgeDays > 90 || !Number.isSafeInteger(limit) || limit < 1 || limit > 2000) throw new Error("refresh-plan max age must be 1-90 days and limit 1-2000");
    const targets = catalogRefreshPlan(store, maxAgeDays, limit);
    await writeJson(cliPath(outputFile), { version: 1, store, generatedAt: new Date().toISOString(), maxAgeDays, targets });
    result = { ok: true, store, outputFile: cliPath(outputFile), targets: targets.length };
  } else {
    throw new Error("tc capture session requires worklist, init, append, evidence, verification-plan, refresh-plan, finalize, or status");
  }
} else if (command === "capture" && subcommand === "build-regular") {
  const browser = arguments_.includes("--browser");
  const [store, inputFile, outputFile, attestationFile] = arguments_.filter((value: string) => value !== "--browser");
  if (!store || !inputFile || !outputFile) throw new Error("tc capture build-regular requires store, input file, and output file");
  const source = JSON.parse(await readFile(cliPath(inputFile), "utf8").then((value) => value.replace(/^\uFEFF/, "")));
  const attestation = attestationFile
    ? JSON.parse(await readFile(cliPath(attestationFile), "utf8").then((value) => value.replace(/^\uFEFF/, ""))) as CaptureAttestation
    : undefined;
  const artifact = await buildRegularCapture(store, source, attestation, browser ? "browser" : "headless");
  const resolvedOutputFile = cliPath(outputFile);
  await writeJson(resolvedOutputFile, artifact);
  result = { ok: true, outputFile: resolvedOutputFile, sourceId: artifact.sourceId, observations: artifact.observations.length, terms: artifact.terms.length, audit: artifact.audit };
} else if (command === "capture" && subcommand === "ingest") {
  const [artifactFile, ...evidenceFiles] = arguments_;
  if (!artifactFile) throw new Error("tc capture ingest requires an artifact file");
  const artifactBytes = await readFile(cliPath(artifactFile));
  const artifact = directCaptureArtifactSchema.parse(JSON.parse(new TextDecoder().decode(artifactBytes).replace(/^\uFEFF/, "")));
  const selectedEvidenceFiles = evidenceFiles.length > 0 ? evidenceFiles : [artifactFile];
  const evidenceInputs: CaptureEvidenceInput[] = await Promise.all(selectedEvidenceFiles.map(async (file: string, index: number) => {
    const extension = path.extname(file).toLowerCase();
    const screenshot = [".png", ".jpg", ".jpeg", ".webp"].includes(extension);
    return {
      body: new Uint8Array(await readFile(cliPath(file))),
      kind: screenshot ? "screenshot" : index === 0 ? artifact.evidence?.kind ?? "raw_payload" : "manifest",
      contentType: extension === ".png" ? "image/png" : extension === ".jpg" || extension === ".jpeg" ? "image/jpeg" : extension === ".webp" ? "image/webp" : "application/json",
    };
  }));
  const client = await mutationClient();
  const ingestion = await ingestDirectCapture(client, artifact, evidenceInputs[0]!.body, evidenceInputs.slice(1), { promote: false });
  const matching = ingestion.ok ? await matchBatch(client, String(ingestion.batchId)) : null;
  if (matching && matching.status !== "passed") throw new Error(`validated capture ${String(ingestion.batchId)} failed matching and was not promoted`);
  const promotion = matching
    ? await client.request(`/internal/capture-batches/${encodeURIComponent(String(ingestion.batchId))}/promote`, { method: "POST" })
    : null;
  result = { ...ingestion, matching, promotion, ...(promotion ? { status: promotion.status } : {}) };
} else if (command === "capture" && subcommand === "ingest-current") {
  const stores = arguments_.length > 0 ? arguments_.map(parseServerCaptureStore) : [...SERVER_CAPTURE_STORES];
  const regularDirectory = path.join(incomeRoot, "grocery", "out", "regular");
  const client = await mutationClient();
  const sourceContractDocument = JSON.parse(await readFile(path.join(platformRoot, "config", "source-contracts.json"), "utf8")) as { version: number; sources: SourceContract[] };
  const captures: Array<Record<string, unknown>> = [];
  for (const store of stores) {
    const file = await findLatestRegularCapture(regularDirectory, store);
    const fresh = await readFreshRegularCapture(file, {
      maximumAgeHours: Number(process.env.TC_SERVER_CAPTURE_MAX_AGE_HOURS ?? 36),
      ...(process.env.TC_SERVER_CAPTURE_ALLOW_PRIOR === "1" ? {} : { requiredDate: omahaDateKey(new Date()) }),
    });
    const artifact = await buildRegularCapture(store, await bindDetectedAdWindow(store, fresh.document as Record<string, unknown>));
    const contract = sourceContractDocument.sources.find((entry) => entry.sourceId === artifact.sourceId);
    if (!contract) throw new Error(`no source contract is registered for ${artifact.sourceId}`);
    const sentinel = evaluateSourceContract(artifact, contract);
    const sentinelReceipt = await client.request("/internal/source-sentinels", { json: {
      sourceId: artifact.sourceId,
      contractVersion: sourceContractDocument.version,
      observedAt: artifact.capturedTo,
      status: sentinel.status,
      checks: sentinel.checks,
      evidence: { file, rows: fresh.rows, newestCaptureDate: fresh.newestCaptureDate },
    }, acceptStatuses: [422] });
    if (sentinel.status !== "pass") throw new Error(`source contract failed for ${artifact.sourceId}: ${stableJson(sentinel.checks)}`);
    const ingestion = await ingestDirectCapture(client, artifact, new Uint8Array(await readFile(file)), [], { promote: false });
    if (!ingestion.ok) throw new Error(`current ${store} capture was rejected: ${stableJson(ingestion)}`);
    const matching = await matchBatch(client, String(ingestion.batchId));
    if (matching.status !== "passed") throw new Error(`validated ${store} capture ${String(ingestion.batchId)} failed matching and was not promoted`);
    const promotion = await client.request(`/internal/capture-batches/${encodeURIComponent(String(ingestion.batchId))}/promote`, { method: "POST" });
    captures.push({ store, file, newestCaptureDate: fresh.newestCaptureDate, oldestCaptureDate: fresh.oldestCaptureDate, sourceRows: fresh.rows, sentinel: sentinelReceipt, ...ingestion, status: promotion.status, matching, promotion });
  }
  result = { ok: true, captures };
} else if (command === "sentinel" && subcommand === "latest") {
  const stores = arguments_.length > 0 ? arguments_.map(parseServerCaptureStore) : [...SERVER_CAPTURE_STORES];
  const regularDirectory = path.join(incomeRoot, "grocery", "out", "regular");
  const client = await mutationClient();
  const sourceContractDocument = JSON.parse(await readFile(path.join(platformRoot, "config", "source-contracts.json"), "utf8")) as { version: number; sources: SourceContract[] };
  const sentinels: Array<Record<string, unknown>> = [];
  for (const store of stores) {
    const file = await findLatestRegularCapture(regularDirectory, store);
    const fresh = await readFreshRegularCapture(file, { maximumAgeHours: Number(process.env.TC_SERVER_CAPTURE_MAX_AGE_HOURS ?? 36) });
    const artifact = await buildRegularCapture(store, await bindDetectedAdWindow(store, fresh.document as Record<string, unknown>));
    const contract = sourceContractDocument.sources.find((entry) => entry.sourceId === artifact.sourceId);
    if (!contract) throw new Error(`no source contract is registered for ${artifact.sourceId}`);
    const evaluated = evaluateSourceContract(artifact, contract);
    const receipt = await client.request("/internal/source-sentinels", { json: { sourceId: artifact.sourceId, contractVersion: sourceContractDocument.version, observedAt: artifact.capturedTo, status: evaluated.status, checks: evaluated.checks, evidence: { file, rows: fresh.rows } }, acceptStatuses: [422] });
    sentinels.push({ store, status: evaluated.status, checks: evaluated.checks, receipt });
  }
  const allSentinelsPass = sentinels.every((entry) => entry.status === "pass");
  result = { ok: allSentinelsPass, sentinels };
  if (!allSentinelsPass) process.exitCode = 2;
} else if (command === "capture" && subcommand === "promote-ready-browser") {
  const client = await mutationClient();
  const ready = await client.request("/internal/capture-batches/ready-browser") as { batches?: Array<{ id: string; source_id: string; captured_to: string }> };
  const promoted: Array<Record<string, unknown>> = [];
  for (const batch of ready.batches ?? []) {
    const matching = await matchBatch(client, batch.id);
    if (matching.status !== "passed") throw new Error(`validated browser batch ${batch.id} failed matching and was not promoted`);
    const promotion = await client.request(`/internal/capture-batches/${encodeURIComponent(batch.id)}/promote`, { method: "POST" });
    promoted.push({ ...batch, matching, promotion });
  }
  result = { ok: true, ready: ready.batches?.length ?? 0, promoted };
} else if (command === "capture" && subcommand === "rematch-promoted") {
  result = await rematchPromotedBatches(await mutationClient(), arguments_.includes("--verbose"));
} else if (command === "capture" && subcommand === "abandon") {
  const batchId = arguments_[0];
  const reason = arguments_.slice(1).join(" ");
  if (!batchId || reason.length < 10) throw new Error("tc capture abandon requires a batch id and a reason of at least 10 characters");
  result = await (await mutationClient()).request(`/internal/capture-batches/${encodeURIComponent(batchId)}/abandon`, { json: { reason } });
} else if (command === "capture" && subcommand === "queue") {
  const [action, ...queueArguments] = arguments_;
  const root = defaultCaptureQueueRoot();
  if (action === "enqueue") {
    const [artifactFile, ...evidenceFiles] = queueArguments;
    if (!artifactFile) throw new Error("tc capture queue enqueue requires an artifact plus screenshot, projected raw, and capture-session manifest evidence");
    result = await enqueueCapture(root, cliPath(artifactFile), evidenceFiles.map(cliPath));
  } else if (action === "drain") {
    const client = await mutationClient();
    const maxJobs = Number(process.env.TC_CAPTURE_QUEUE_MAX_JOBS_PER_DRAIN ?? 4);
    const drained = await drainBrowserCaptureQueue(client, root, maxJobs);
    result = drained;
    if (!drained.ok) process.exitCode = 2;
  } else if (action === "compact") {
    result = { ok: true, ...(await compactPromotedCaptureQueue(root)) };
  } else if (action === "status" || action === "watchdog") {
    const watchdogClient = action === "watchdog" ? await mutationClient() : null;
    const reconciliation = watchdogClient
      ? await reconcileCaptureQueueRemote(root, (batchId) => watchdogClient.request(`/internal/capture-batches/${encodeURIComponent(batchId)}/status`))
      : null;
    const compaction = watchdogClient ? await compactPromotedCaptureQueue(root) : null;
    const filesystem = await verifyCaptureQueueFilesystem(root);
    const status = await captureQueueStatus(root, {
      maxPendingMinutes: Number(process.env.TC_CAPTURE_QUEUE_MAX_PENDING_MINUTES ?? 180),
      maxAttempts: Number(process.env.TC_CAPTURE_QUEUE_MAX_ATTEMPTS ?? 5),
    });
    const cycle = await browserCaptureCycleStatus(root);
    const healthy = status.ok && !cycle.alertDue && (reconciliation?.errors ?? 0) === 0;
    const queueResult = { ...status, ok: healthy, filesystem, cycle, ...(reconciliation ? { reconciliation } : {}), ...(compaction ? { compaction } : {}) };
    result = queueResult;
    if (action === "watchdog") {
      const alert = await watchdogClient!.request("/internal/operational-alerts", { json: {
        key: "pc-browser-capture-queue",
        title: "PC browser capture pipeline is unhealthy",
        status: healthy ? "resolved" : "firing",
        observedAt: new Date().toISOString(),
        evidence: {
          pending: status.pending,
          retrying: status.retrying,
          completed: status.completed,
          rejected: status.rejected,
          oldestPendingMinutes: status.oldestPendingMinutes,
          highestAttempts: status.highestAttempts,
          unhealthyJobs: status.unhealthyJobs,
          filesystem,
          cycle,
          reconciliation,
        },
      } });
      result = { ...queueResult, alert };
      if (!healthy) process.exitCode = 2;
    }
  } else {
    throw new Error("tc capture queue requires enqueue, drain, status, watchdog, or compact");
  }
} else if (command === "capture" && subcommand === "journal") {
  const action = arguments_[0];
  if (action === "checkpoint") result = await checkpointCaptureJournal();
  else if (action === "restore") result = await restoreCaptureJournal(arguments_.includes("--force"));
  else throw new Error("tc capture journal requires checkpoint or restore [--force]");
} else if (command === "match" && subcommand === "batch") {
  const batchId = arguments_[0];
  if (!batchId) throw new Error("tc match batch requires a capture batch id");
  result = await matchBatch(await mutationClient(), batchId);
} else if (command === "capture" && subcommand === "validate") {
  const file = arguments_[0];
  if (!file) throw new Error("tc capture validate requires a JSON file");
  const parsed = JSON.parse(await readFile(cliPath(file), "utf8"));
  const direct = directCaptureArtifactSchema.safeParse(parsed);
  result = direct.success
    ? { ok: true, kind: "direct-capture", sourceId: direct.data.sourceId, observations: direct.data.observations.length, terms: direct.data.terms.length, audit: direct.data.audit }
    : { ok: true, kind: "observation-chunk", observations: observationChunkSchema.parse(Array.isArray(parsed) ? { observations: parsed } : parsed).observations.length };
} else if (command === "accuracy" && subcommand === "revalidate") {
  const revalidationNow = new Date();
  const due = new Date(revalidationNow.getTime() + 12 * 60 * 60 * 1000);
  result = await (await mutationClient()).request("/internal/accuracy/draws", { json: { marketId: "omaha", seed: `revalidate-${revalidationNow.toISOString().slice(0, 10)}`, protocolVersion: "winner-challenger-v1", sampleSize: 1, dueAt: due.toISOString() } });
} else if (command === "accuracy" && subcommand === "draw") {
  const now = new Date();
  const due = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000);
  result = await (await mutationClient()).request("/internal/accuracy/draws", { json: { marketId: "omaha", seed: arguments_[0] ?? `week-${now.toISOString().slice(0, 10)}`, protocolVersion: "blind-cell-v1", sampleSize: 100, dueAt: due.toISOString() } });
} else if (command === "accuracy" && subcommand === "show") {
  const drawId = arguments_.find((value: string) => value !== "--reveal");
  const query = new URLSearchParams();
  if (drawId) query.set("id", drawId);
  if (arguments_.includes("--reveal")) query.set("reveal", "1");
  result = await (await mutationClient()).request(`/internal/accuracy/draw${query.size ? `?${query}` : ""}`);
} else if (command === "accuracy" && subcommand === "verdict") {
  const file = arguments_[0];
  if (!file) throw new Error("tc accuracy verdict requires a JSON file");
  result = await (await mutationClient()).request("/internal/accuracy/verdicts", { json: JSON.parse(await readFile(cliPath(file), "utf8")) });
} else if (command === "commodity" && subcommand === "add") {
  result = await commodityAdd(arguments_[0]);
} else if (command === "ingredient" && subcommand === "apply") {
  const file = arguments_[0];
  if (!file) throw new Error("tc ingredient apply requires an ingredient researcher output JSON file");
  const document = JSON.parse(await readFile(cliPath(file), "utf8")) as { finalOutput?: unknown };
  const research = ingredientPriceResearchSchema.parse(document.finalOutput ?? document);
  const verifiedUnitPrices = research.stores.flatMap((store) => store.outcome === "priced" && store.perUnitMicros !== null ? [store.perUnitMicros / 1_000_000] : []);
  const bandMin = verifiedUnitPrices.length > 0 ? Math.max(0.01, Math.floor(Math.min(...verifiedUnitPrices) * 0.35 * 100) / 100) : undefined;
  const bandMax = verifiedUnitPrices.length > 0 ? Math.ceil(Math.max(...verifiedUnitPrices) * 3 * 100) / 100 : undefined;
  result = research.disposition === "available" && research.commodityProposal
    ? await commodityAddSpecification({
      ...research.commodityProposal,
      ...(bandMin !== undefined ? { bandMin } : {}),
      ...(bandMax !== undefined ? { bandMax } : {}),
    })
    : { ok: true, applied: false, gapId: research.gapId, disposition: research.disposition };
} else if (command === "ingredient" && subcommand === "apply-ready") {
  const limit = arguments_[0] === undefined ? 20 : Number(arguments_[0]);
  if (!Number.isInteger(limit) || limit < 1 || limit > 50) throw new Error("tc ingredient apply-ready limit must be between 1 and 50");
  const client = await mutationClient();
  await client.request("/internal/ingredient-gaps/reconcile", { method: "POST" });
  const response = await client.request("/internal/ingredient-gaps?status=ready_to_publish", { method: "GET" }) as {
    gaps?: Array<{ id?: string; research_json?: string | null }>;
  };
  const applied: Array<{ gapId: string; commodityId: string }> = [];
  const failed: Array<{ gapId: string; error: string }> = [];
  for (const gap of (response.gaps ?? []).slice(0, limit)) {
    try {
      if (!gap.id || !gap.research_json) throw new Error("ready ingredient gap omitted durable research evidence");
      const research = ingredientPriceResearchSchema.parse(JSON.parse(gap.research_json));
      if (research.disposition !== "available" || !research.commodityProposal) throw new Error("ready ingredient gap does not contain an available commodity proposal");
      const verifiedUnitPrices = research.stores.flatMap((store) => store.outcome === "priced" && store.perUnitMicros !== null ? [store.perUnitMicros / 1_000_000] : []);
      const bandMin = verifiedUnitPrices.length > 0 ? Math.max(0.01, Math.floor(Math.min(...verifiedUnitPrices) * 0.35 * 100) / 100) : undefined;
      const bandMax = verifiedUnitPrices.length > 0 ? Math.ceil(Math.max(...verifiedUnitPrices) * 3 * 100) / 100 : undefined;
      await commodityAddSpecification({
        ...research.commodityProposal,
        ...(bandMin !== undefined ? { bandMin } : {}),
        ...(bandMax !== undefined ? { bandMax } : {}),
      });
      applied.push({ gapId: research.gapId, commodityId: research.commodityProposal.id });
    } catch (error) {
      const message = error instanceof Error ? (error.stack ?? error.message) : String(error);
      const requiresJudgment = /(?:collide|would also claim|already exists|matcher surgery)/i.test(message);
      if (gap.id) await client.request(`/internal/ingredient-gaps/${encodeURIComponent(gap.id)}/publication-failure`, {
        method: "POST", json: { error: message, requiresJudgment },
      });
      failed.push({ gapId: gap.id ?? "unknown", error: message });
    }
  }
  result = { ok: true, applied, failed };
} else if (command === "recipe" && subcommand === "add") {
  result = await recipeAdd(arguments_[0]);
} else if (command === "recipe" && subcommand === "bundles") {
  let releaseId = arguments_[0];
  const client = await mutationClient();
  if (!releaseId) {
    const current = await client.request("/api/v2/releases/current", { method: "GET" });
    releaseId = String(current.releaseId ?? "");
  }
  if (!releaseId) throw new Error("tc recipe bundles could not resolve the current release id");
  result = await client.request(`/internal/releases/${encodeURIComponent(releaseId)}/recipe-bundles`, { method: "POST" });
} else if (command === "cache" && subcommand === "purge") {
  result = await (await mutationClient()).request("/internal/cache/purge", { method: "POST" });
} else if (command === "efficiency" && subcommand === "record") {
  const file = arguments_[0];
  if (!file) throw new Error("tc efficiency record requires a D1 efficiency report JSON file");
  const report = JSON.parse((await readFile(cliPath(file), "utf8")).replace(/^\uFEFF/, "")) as {
    ok?: boolean; period?: string; policyVersion?: number; findings?: Array<Record<string, unknown>>; queries?: Array<Record<string, unknown>>;
  };
  if (typeof report.ok !== "boolean" || !Array.isArray(report.findings)) throw new Error("D1 efficiency report is incomplete");
  result = await (await mutationClient()).request("/internal/operational-alerts", { json: {
    key: "d1-efficiency-budget",
    title: report.ok ? "D1 efficiency budgets recovered" : `D1 efficiency exceeded ${report.findings.length} budget${report.findings.length === 1 ? "" : "s"}`,
    status: report.ok ? "resolved" : "firing",
    observedAt: new Date().toISOString(),
    evidence: { period: report.period ?? "unknown", policyVersion: report.policyVersion ?? null, findings: report.findings.slice(0, 50), queries: (report.queries ?? []).slice(0, 10) },
  } });
} else if (command === "recipe" && subcommand === "suggest") {
  const file = arguments_[0];
  if (!file) throw new Error("tc recipe suggest requires a request JSON file");
  result = await (await mutationClient()).request("/internal/recipe-suggestions", { json: JSON.parse(await readFile(cliPath(file), "utf8")) });
} else if (command === "ingredient" && subcommand === "discover") {
  const supplied = arguments_[0] ? JSON.parse(await readFile(cliPath(arguments_[0]), "utf8")) as Record<string, unknown> : {};
  const requestedAt = typeof supplied.requestedAt === "string" ? supplied.requestedAt : new Date().toISOString();
  const generatedId = `ingredient_discovery_${requestedAt.replace(/[^0-9]/g, "").slice(0, 14)}_${crypto.randomUUID().replaceAll("-", "").slice(0, 8)}`;
  const request = {
    id: supplied.id ?? generatedId,
    request: supplied.request ?? "Randomly source diverse, externally verified complete meal-prep recipes solely to discover required purchased ingredients missing from the active Omaha grocery catalog. Preserve every quantified required ingredient, ignore only true process water and optional garnish, and exclude seafood and ground chicken.",
    requestedAt,
    sourceRef: supplied.sourceRef ?? "codex-task://ingredient-discovery",
    mode: "missing-ingredients",
    targetMissingIngredients: supplied.targetMissingIngredients ?? 50,
    targetPublishedIngredients: supplied.targetPublishedIngredients ?? supplied.targetMissingIngredients ?? 50,
  };
  result = await (await mutationClient()).request("/internal/recipe-suggestions", { json: request });
} else if (command === "ingredient" && subcommand === "campaign") {
  const [requestId, action, target, workers, batchSize] = arguments_;
  if (!requestId || !action || !["pause", "resume", "configure", "freeze-discovery", "resume-discovery"].includes(action)) {
    throw new Error("tc ingredient campaign requires <request-id> pause|resume|configure|freeze-discovery|resume-discovery [target-published] [workers] [batch-size]");
  }
  result = await (await mutationClient()).request(`/internal/ingredient-campaigns/${encodeURIComponent(requestId)}/control`, { json: {
    action,
    ...(target !== undefined ? { targetPublishedIngredients: Number(target) } : {}),
    ...(workers !== undefined ? { desiredPricingWorkers: Number(workers) } : {}),
    ...(batchSize !== undefined ? { publishBatchSize: Number(batchSize) } : {}),
  } });
} else if (command === "ingredient" && subcommand === "qa-retry") {
  result = await (await mutationClient()).request("/internal/ingredient-gaps/qa-retry", {
    json: { ...(arguments_.length > 0 ? { gapIds: arguments_ } : {}) },
  });
} else if (command === "ingredient" && subcommand === "qa-not-found") {
  const [gapId, storeLocationId, sourceUrl, ...evidenceParts] = arguments_;
  const evidenceSummary = evidenceParts.join(" ").trim();
  if (!gapId || !storeLocationId || !sourceUrl || evidenceSummary.length < 30) {
    throw new Error("tc ingredient qa-not-found requires <gap-id> <store-location-id> <source-url> <evidence-summary>");
  }
  result = await (await mutationClient()).request(`/internal/ingredient-gaps/${encodeURIComponent(gapId)}/qa-not-found`, {
    json: { storeLocationId, sourceUrl, evidenceSummary },
  });
} else if (command === "ingredient" && subcommand === "qa-resolve") {
  const [gapId, resolution, commodityId, ...reasonParts] = arguments_;
  if (!gapId || !resolution || !["existing_alias", "excluded_noncommodity"].includes(resolution)) {
    throw new Error("tc ingredient qa-resolve requires <gap-id> existing_alias|excluded_noncommodity <commodity-id|-> <reason>");
  }
  const reason = reasonParts.join(" ").trim();
  if (reason.length < 10) throw new Error("tc ingredient qa-resolve requires a durable reason of at least 10 characters");
  result = await (await mutationClient()).request(`/internal/ingredient-gaps/${encodeURIComponent(gapId)}/qa-resolution`, {
    json: { resolution, commodityId: commodityId && commodityId !== "-" ? commodityId : null, reason },
  });
} else if (command === "ingredient" && subcommand === "publication-retry") {
  if (arguments_.length === 0) throw new Error("tc ingredient publication-retry requires one or more gap ids");
  const client = await mutationClient();
  const retried = [];
  for (const gapId of arguments_) {
    retried.push(await client.request(`/internal/ingredient-gaps/${encodeURIComponent(gapId)}/publication-retry`, { method: "POST" }));
  }
  result = { ok: true, retried };
} else if (command === "ingredient" && subcommand === "reconcile") {
  result = await (await mutationClient()).request("/internal/ingredient-gaps/reconcile", { method: "POST" });
} else if (command === "ingredient" && subcommand === "status") {
  const query = arguments_[0] ? `?status=${encodeURIComponent(arguments_[0])}` : "";
  result = await (await mutationClient()).request(`/internal/ingredient-gaps${query}`, { method: "GET" });
} else if (command === "recipe" && subcommand === "wave") {
  const [action, waveId, value] = arguments_;
  if (!action || !waveId) throw new Error("tc recipe wave requires snapshot|published|corrective and a wave id");
  const client = await mutationClient();
  if (action === "snapshot") {
    if (!value) throw new Error("tc recipe wave snapshot requires a content batch id");
    result = await client.request("/internal/recipe-waves/snapshot", { json: { id: waveId, contentBatchId: value } });
  } else if (action === "published") {
    if (!value) throw new Error("tc recipe wave published requires a release id");
    result = await client.request(`/internal/recipe-waves/${encodeURIComponent(waveId)}/published`, { json: { releaseId: value } });
  } else if (action === "corrective") {
    const created = await client.request(`/internal/recipe-waves/${encodeURIComponent(waveId)}/corrective-release`, { method: "POST" }) as { correctiveReleaseId?: string };
    if (!created.correctiveReleaseId) throw new Error("corrective release endpoint omitted the release id");
    const validation = await client.request(`/internal/releases/${encodeURIComponent(created.correctiveReleaseId)}/validate`, { method: "POST", acceptStatuses: [422] });
    if (validation.state !== "validated") throw new Error(`corrective release ${created.correctiveReleaseId} failed validation`);
    const publication = await client.request(`/internal/releases/${encodeURIComponent(created.correctiveReleaseId)}/publish`, { method: "POST" });
    const recorded = await client.request(`/internal/recipe-waves/${encodeURIComponent(waveId)}/corrected`, { method: "POST" });
    result = { ok: true, created, validation, publication, recorded };
  } else {
    throw new Error(`unknown recipe wave action ${action}`);
  }
} else {
  const requestedCommand = [command, subcommand, ...arguments_].filter(Boolean).join(" ");
  const isHelpRequest = command === "help" && subcommand === undefined && arguments_.length === 0;
  result = {
    ok: isHelpRequest,
    ...(!isHelpRequest ? { error: `Unknown command: ${requestedCommand}` } : {}),
    usage: [
      "tc status", "tc doctor", "tc triage [status|run|reconcile]", "tc triage review <id> <file>|plan|resolve|needs-operator <id> <file>", "tc config generate|check|deploy|archives|archive <id>",
      "tc schedules check|deploy", "tc promotion sync|status|reconcile|due [headless|browser]|claim <headless|browser> [owner]|complete <completed|failed> <id...>", "tc agents check|deploy", "tc content show|create <json>|items <batch> <json>|audit <batch> <json>|promote <batch>", "tc backup checkpoint|trigger [--replica]", "tc restore trigger [--force]|record <file>|show|cleanup <file>", "tc archive forecast|plan [cutoff] [--execute]|export <manifest> <json>|upload <manifest> <parquet>|execute <manifest> <sha256>", "tc storage migrate-releases|gc-plan [days] [--execute]|gc-sweep <run> [--execute]", "tc cleanup index|plan [--execute]|export <run> <json>|upload <run> <parquet>|execute <run> <sha256>", "tc evidence record <file>|show [gate]|accrue", "tc entitlement record <file>|show", "tc drill release-freeze|ghost-clobber [release-id]|chaos <kind>|stale-capture [artifact]", "tc job start|finish|dispatch <job> [status|reason]|github-runs [limit]",
      "tc release reject <release-id>", "tc ghost reconcile [release-id]", "tc transition readiness|retire <schedule-id>", "tc efficiency record <report.json>", "tc recipe bundles [release-id]", "tc cache purge",
        "tc run daily --dry", "tc parity", "tc replay", "tc engine parity [legacy|direct|all]", "tc capture validate|ingest <file> [evidence]", "tc capture build-regular <store> <input> <output> [attestation] [--browser]",
        "tc capture metrics [limit]", "tc capture coordinator status|next|heartbeat|fail|challenge|resolve", "tc capture session worklist|init|append|evidence|verification-plan|finalize|status",
      "tc capture queue enqueue <artifact> <screenshot...>", "tc capture queue drain|status|watchdog", "tc capture journal checkpoint|restore [--force]",
      "tc capture ingest-current [bakers family-fare hy-vee]|promote-ready-browser|rematch-promoted|abandon <batch-id> <reason>",
      "tc accuracy draw [seed]|revalidate", "tc accuracy show [draw-id] [--reveal]", "tc accuracy verdict <file>",
      "tc sentinel latest [bakers family-fare hy-vee]",
      "tc match batch <batch-id>", "tc commodity add <file>", "tc ingredient discover [request-file]", "tc ingredient status [state]", "tc ingredient apply <research-output>", "tc ingredient apply-ready", "tc recipe add <file>",
    ],
  };
  if (!isHelpRequest) process.exitCode = 2;
}

console.log(JSON.stringify(result, null, 2));
