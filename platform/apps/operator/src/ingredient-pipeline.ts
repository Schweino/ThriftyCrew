import { OMAHA_GROCERY_STORE_LOCATION_IDS } from "@thriftycrew/contracts";
import type { MutationClient } from "@thriftycrew/daily/client";
import { readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { captureHeadlessDiscovery, captureHeadlessVerification, claimSearchTerms, mapWithConcurrency, type HeadlessStore } from "./headless-targeted-capture";
import { buildIngredientCapturePayload, buildIngredientQaPayload, type AdapterChunk, type ClaimedCheck } from "./ingredient-targeted-capture";

type ClaimResponse = { checks?: ClaimedCheck[] };

export type IngredientPipelineLane = "catalog" | "capture" | "qa";
export type IngredientPipelineTickOptions = {
  owner?: string;
  limitPerStore?: number;
  storeLocationIds?: string[];
  lanes?: IngredientPipelineLane[];
  orchestration?: boolean;
};

type LaneResult = { completed: number; error: string | null };

const HEADLESS_STORES: Partial<Record<string, HeadlessStore>> = {
  "bakers-saddle-creek": "bakers",
  "family-fare-omaha-6401": "family-fare",
  "hy-vee-omaha-1465": "hy-vee",
};
const KROGER_CREDENTIALS_FILE = path.resolve(import.meta.dirname, "../../../..", "grocery", ".krogerkey");
const FAMILY_FARE_CATALOG_FILE = path.resolve(import.meta.dirname, "../../../..", "grocery", "out", "regular",
  `family-fare-regular-${new Date().toISOString().slice(0, 10)}.json`);

const pause = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function drainCatalogLane(client: MutationClient, storeLocationId: string, owner: string, limit: number): Promise<number> {
  const claimed = await client.request("/internal/ingredient-pricing/store-checks/claim", {
    json: { storeLocationId, owner, lane: "catalog", limit, leaseSeconds: 300 },
  }) as ClaimResponse;
  let completed = 0;
  await Promise.all((claimed.checks ?? []).map(async (check) => {
    const id = String(check.id);
    const leaseGeneration = Number(check.lease_generation);
    if (!id || !Number.isInteger(leaseGeneration) || leaseGeneration < 1) throw new Error("claimed store check omitted its lease fence");
    try {
      await client.request(`/internal/ingredient-pricing/store-checks/${encodeURIComponent(id)}/catalog-resolve`, {
        json: { owner, leaseGeneration, leaseSeconds: 300 },
      });
      completed += 1;
    } catch (error) {
      await failClaimedChecks(client, [check], error);
    }
  }));
  return completed;
}

async function uploadEvidence(client: MutationClient, check: ClaimedCheck, kind: "producer" | "verifier", chunk: AdapterChunk) {
  const claim = { checkId: check.id, queryPlanHash: check.query_plan_hash };
  const evidenceChunk = compactEvidenceChunkForCheck(check, chunk);
  const response = await client.request("/internal/ingredient-pricing/evidence", { json: {
    checkId: check.id, kind, sourceUrl: evidenceChunk.canary.evidenceUrl, observedAt: evidenceChunk.canary.observedAt,
    document: kind === "producer" ? { claim, chunks: [evidenceChunk] } : { claim, verification: evidenceChunk },
  } }) as { evidence?: unknown };
  if (!response.evidence) throw new Error(`evidence upload omitted its immutable pointer for ${check.id}`);
  return response.evidence as Parameters<typeof buildIngredientCapturePayload>[2];
}

function normalizedEvidenceTerm(value: unknown): string {
  return String(value ?? "").trim().toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

/**
 * Headless APIs can return hundreds of products for a broad alias. The full
 * chunk remains local for deterministic candidate selection, while immutable
 * evidence is scoped to the claimed commodity and removes duplicated visible/
 * structured projections already preserved in the canonical offer.
 */
export function compactEvidenceChunkForCheck(check: ClaimedCheck, chunk: AdapterChunk): AdapterChunk {
  if (chunk.phase !== "discovery") return chunk;
  const proposal = JSON.parse(String(check.commodity_proposal_json ?? "{}")) as { searchTerms?: string[] };
  const expected = new Set((proposal.searchTerms ?? []).map(normalizedEvidenceTerm).filter(Boolean));
  if (expected.size === 0) return chunk;
  const terms = (chunk.terms ?? []).filter((term) => expected.has(normalizedEvidenceTerm(term.query))).map((term) => {
    const excluded = Array.isArray((term as any).excludedResults) ? (term as any).excludedResults.length : 0;
    const { excludedResults: _excludedResults, ...rest } = term as any;
    return excluded > 0 ? { ...rest, reason: `${excluded} source result(s) explicitly excluded; detailed source envelope retained in the local capture artifact` } : rest;
  });
  const rows = (chunk.rows ?? []).filter((row: any) => expected.has(normalizedEvidenceTerm(row.q ?? row.term))).map((row: any) => {
    const capture = row._capture ?? {};
    const compactCapture = { capturedAt: capture.capturedAt, pageUrl: capture.pageUrl, location: capture.location,
      priceMode: capture.priceMode, pageIndex: capture.pageIndex, resultIndex: capture.resultIndex,
      pageState: capture.pageState, offer: capture.offer, parser: capture.parser };
    return { ...(row.q !== undefined ? { q: row.q } : {}), ...(row.term !== undefined ? { term: row.term } : {}),
      id: row.id, name: row.name, n: row.n, size: row.size, url: row.url, taxonomy_path: row.taxonomy_path,
      _capture: compactCapture };
  });
  return { ...chunk, terms, rows };
}

export function storeCheckFailureDisposition(reason: unknown, now = new Date()): { failureClass: "transient" | "adapter_quarantined"; retryAt: string | null } {
  const message = String(reason instanceof Error ? reason.message : reason);
  if (/\[headless_source_limit\]/i.test(message)) return { failureClass: "adapter_quarantined", retryAt: null };
  const retryDelay = /source throttled/i.test(message) ? 5 * 60_000 : 60_000;
  return { failureClass: "transient", retryAt: new Date(now.getTime() + retryDelay).toISOString() };
}

async function failClaimedChecks(client: MutationClient, checks: ClaimedCheck[], reason: unknown): Promise<void> {
  const message = String(reason instanceof Error ? reason.message : reason);
  console.error(JSON.stringify({
    event: "ingredient_store_check_failed",
    checkIds: checks.map((check) => check.id),
    stores: [...new Set(checks.map((check) => check.store_location_id))],
    reason: message.slice(0, 5000),
  }));
  // Freshop reports throttling as either HTTP 429 or HTTP 400 with
  // {"error_code":429}. Give the shared retailer quota time to recover
  // instead of allowing the event loop to amplify the refusal every minute.
  const disposition = storeCheckFailureDisposition(reason);
  await Promise.allSettled(checks.map((check) => client.request(`/internal/ingredient-pricing/store-checks/${encodeURIComponent(check.id)}/fail`, { json: {
    owner: check.lease_owner, leaseGeneration: Number(check.lease_generation), failureClass: disposition.failureClass,
    reason: message.slice(0, 5000), challengeId: null, retryAt: disposition.retryAt,
  } })));
}

export function ingredientQaFailureAction(reason: unknown): "reject_to_capture" | "retry" {
  const message = String(reason instanceof Error ? reason.message : reason);
  return /(?:independent (?:pass|verifier) found an eligible exact candidate|independent (?:verification|verifier) (?:does not|did not) reproduce the frozen winner)/i.test(message)
    ? "reject_to_capture"
    : "retry";
}

export function isIdempotentQaResumeConflict(reason: unknown): boolean {
  return /QA completion (?:rejected by|lost its) lease fence(?: or lane boundary)?/i
    .test(String(reason instanceof Error ? reason.message : reason));
}

export function isIdempotentCaptureResumeConflict(reason: unknown): boolean {
  return /capture completion rejected by lease fence or lane boundary/i
    .test(String(reason instanceof Error ? reason.message : reason));
}

async function rejectQaToCapture(client: MutationClient, check: ClaimedCheck, reason: unknown): Promise<void> {
  const message = String(reason instanceof Error ? reason.message : reason).slice(0, 2000);
  console.error(JSON.stringify({ event: "ingredient_store_qa_rejected_to_capture", checkId: check.id,
    store: check.store_location_id, reason: message }));
  await client.request(`/internal/ingredient-pricing/store-checks/${encodeURIComponent(check.id)}/qa-reject`, { json: {
    owner: check.lease_owner, leaseGeneration: Number(check.lease_generation),
    validatorVersion: "targeted-independent-verifier-v1", reason: message,
  } });
}

async function drainHeadlessCaptureLane(client: MutationClient, storeLocationId: string, adapter: HeadlessStore, owner: string, limit: number): Promise<number> {
  const claimed = await client.request("/internal/ingredient-pricing/store-checks/claim", {
    json: { storeLocationId, owner, lane: "targeted_refresh", limit: Math.min(50, limit), leaseSeconds: 900 },
  }) as ClaimResponse;
  const checks = claimed.checks ?? [];
  if (checks.length === 0) return 0;
  const file = path.join(os.tmpdir(), `tc-ingredient-${adapter}-capture-${process.pid}-${Date.now()}.json`);
  try {
    const terms = claimSearchTerms(checks);
    const chunk = await captureHeadlessDiscovery(adapter, terms, file, {
      krogerCredentialsFile: KROGER_CREDENTIALS_FILE, familyFareCatalogFile: FAMILY_FARE_CATALOG_FILE,
    });
    const completions = await mapWithConcurrency(checks, Math.min(10, checks.length), async (check) => {
      try {
        const evidence = await uploadEvidence(client, check, "producer", chunk);
        const payload = await buildIngredientCapturePayload(check, [chunk], evidence);
        await client.request(`/internal/ingredient-pricing/store-checks/${encodeURIComponent(check.id)}/capture-result`, { json: payload });
        return 1;
      } catch (error) {
        await failClaimedChecks(client, [check], error);
        return 0;
      }
    });
    return completions.reduce<number>((sum, value) => sum + value, 0);
  } catch (error) {
    await failClaimedChecks(client, checks, error);
    return 0;
  } finally {
    await rm(file, { force: true }).catch(() => undefined);
  }
}

async function drainHeadlessQaLane(client: MutationClient, storeLocationId: string, adapter: HeadlessStore, owner: string, limit: number): Promise<number> {
  const claimed = await client.request("/internal/ingredient-pricing/store-checks/claim", {
    json: { storeLocationId, owner, lane: "qa", limit: Math.min(50, limit), leaseSeconds: 900 },
  }) as ClaimResponse;
  const checks = claimed.checks ?? [];
  if (checks.length === 0) return 0;
  const file = path.join(os.tmpdir(), `tc-ingredient-${adapter}-qa-${process.pid}-${Date.now()}.json`);
  const discoveryFile = `${file}.discovery.json`;
  try {
    const verification = await captureHeadlessVerification(adapter, checks, file, {
      krogerCredentialsFile: KROGER_CREDENTIALS_FILE, familyFareCatalogFile: FAMILY_FARE_CATALOG_FILE,
    });
    const discovery = JSON.parse(await readFile(discoveryFile, "utf8")) as AdapterChunk;
    const completions = await mapWithConcurrency(checks, Math.min(10, checks.length), async (check) => {
      try {
        const captured = JSON.parse(String(check.capture_result_json ?? "null")) as { outcome?: string } | null;
        const chunk = captured?.outcome === "priced" ? verification : discovery;
        const evidence = await uploadEvidence(client, check, "verifier", chunk);
        const payload = buildIngredientQaPayload(check, chunk, evidence as Parameters<typeof buildIngredientQaPayload>[2]);
        await client.request(`/internal/ingredient-pricing/store-checks/${encodeURIComponent(check.id)}/qa-complete`, { json: payload });
        return 1;
      } catch (error) {
        if (ingredientQaFailureAction(error) === "reject_to_capture") await rejectQaToCapture(client, check, error);
        else await failClaimedChecks(client, [check], error);
        return 0;
      }
    });
    return completions.reduce<number>((sum, value) => sum + value, 0);
  } catch (error) {
    await failClaimedChecks(client, checks, error);
    return 0;
  } finally {
    await Promise.all([rm(file, { force: true }), rm(discoveryFile, { force: true })]).catch(() => undefined);
  }
}

async function isolateLane(work: () => Promise<number>): Promise<LaneResult> {
  try {
    return { completed: await work(), error: null };
  } catch (error) {
    return { completed: 0, error: String(error instanceof Error ? error.message : error).slice(0, 5000) };
  }
}

export async function settleIndependentLanes(
  work: Partial<Record<IngredientPipelineLane, () => Promise<number>>>,
): Promise<Record<IngredientPipelineLane, LaneResult>> {
  const skipped = () => Promise.resolve({ completed: 0, error: null });
  const [catalog, capture, qa] = await Promise.all([
    work.catalog ? isolateLane(work.catalog) : skipped(),
    work.capture ? isolateLane(work.capture) : skipped(),
    work.qa ? isolateLane(work.qa) : skipped(),
  ]);
  return { catalog, capture, qa };
}

export async function drainIndependentStoreLanes(
  client: MutationClient,
  storeLocationId: string,
  owner: string,
  limit: number,
  lanes: ReadonlySet<IngredientPipelineLane>,
) {
  const adapter = HEADLESS_STORES[storeLocationId];
  // These claims are state-disjoint and lease-fenced. Keeping them in separate
  // promises lets an existing QA backlog drain while a producer fills the next
  // generation, and one failed source role cannot cancel either sibling role.
  const { catalog, capture, qa } = await settleIndependentLanes({
    ...(lanes.has("catalog") ? { catalog: () => drainCatalogLane(client, storeLocationId, `${owner}-catalog`, limit) } : {}),
    ...(lanes.has("capture") && adapter ? { capture: () => drainHeadlessCaptureLane(client, storeLocationId, adapter, `${owner}-capture`, limit) } : {}),
    ...(lanes.has("qa") && adapter ? { qa: () => drainHeadlessQaLane(client, storeLocationId, adapter, `${owner}-qa`, limit) } : {}),
  });
  return { storeLocationId, catalogResolved: catalog.completed, captured: capture.completed, qaCompleted: qa.completed,
    errors: { catalog: catalog.error, capture: capture.error, qa: qa.error } };
}

export async function runIngredientPipelineTick(client: MutationClient, options: IngredientPipelineTickOptions = {}) {
  const owner = options.owner ?? `ingredient-coordinator-${process.pid}`;
  const limit = options.limitPerStore ?? 50;
  const configuredStores = options.storeLocationIds ?? [...OMAHA_GROCERY_STORE_LOCATION_IDS];
  const invalidStores = configuredStores.filter((store) => !OMAHA_GROCERY_STORE_LOCATION_IDS.includes(store as typeof OMAHA_GROCERY_STORE_LOCATION_IDS[number]));
  if (invalidStores.length > 0) throw new Error(`unknown Omaha store lane(s): ${invalidStores.join(", ")}`);
  const lanes = new Set<IngredientPipelineLane>(options.lanes ?? ["catalog", "capture", "qa"]);
  const orchestration = options.orchestration ?? true;
  const claimedEvents = orchestration ? await client.request("/internal/pipeline/outbox/claim", {
    json: { owner, limit: 200, leaseSeconds: 120 },
  }) as { events?: Array<{ id?: unknown; lease_generation?: unknown }> } : { events: [] };
  const catalog = orchestration
    ? await client.request("/internal/ingredient-pricing/catalog/materialize", { method: "POST", retrySafe: true })
    : { skipped: true };
  // Queue definition work before store I/O. The definition agent is an
  // independent pool, so it can lock identities while catalog lanes drain.
  const definitionPlanning = orchestration
    ? await client.request("/internal/ingredient-pricing/proposals/plan", { method: "POST" }) as Record<string, unknown>
    : { skipped: true };
  const storeResults = await Promise.all(configuredStores.map((storeLocationId) =>
    drainIndependentStoreLanes(client, storeLocationId, `${owner}-${storeLocationId}`, limit, lanes)));
  const reconciliation = orchestration
    ? await client.request("/internal/ingredient-pricing/reconcile", { method: "POST" }) as { repaired?: string[] }
    : { repaired: [] };
  if (orchestration) await Promise.all((claimedEvents.events ?? []).map((event) => client.request(`/internal/pipeline/outbox/${encodeURIComponent(String(event.id))}/ack`, {
    json: { owner, leaseGeneration: Number(event.lease_generation) },
  })));
  const status = orchestration ? await client.request("/internal/ingredient-pricing/status") : null;
  return { ok: true, catalog, outboxEvents: (claimedEvents.events ?? []).length, stores: storeResults, definitionPlanning, reconciliation, status,
    progressed: (claimedEvents.events ?? []).length > 0 || (reconciliation.repaired ?? []).length > 0
      || storeResults.some((row) => row.catalogResolved > 0 || row.captured > 0 || row.qaCompleted > 0) || definitionPlanning.queued === true };
}

export async function runIngredientPipeline(client: MutationClient, options: IngredientPipelineTickOptions & { once?: boolean } = {}) {
  let idleDelay = 1_000;
  let ticks = 0;
  for (;;) {
    const tick = await runIngredientPipelineTick(client, options);
    ticks += 1;
    if (options.once) return { ...tick, ticks };
    if (tick.progressed) { idleDelay = 1_000; continue; }
    await pause(idleDelay);
    idleDelay = Math.min(15_000, idleDelay * 2);
  }
}
