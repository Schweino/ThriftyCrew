import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { directCaptureArtifactSchema, observationChunkSchema } from "@thriftycrew/contracts";
import { deployConfiguration, ingestDirectCapture, MutationClient, publishNativeRelease, replayCurrentArtifact, type CaptureEvidenceInput } from "@thriftycrew/daily/client";
import { buildCurrentBridge } from "@thriftycrew/daily/legacy";
import { buildRegularCapture, type CaptureAttestation } from "@thriftycrew/daily/direct";
import { evaluateSourceContract, type SourceContract } from "@thriftycrew/daily/source-contracts";
import { buildNativeRelease } from "@thriftycrew/daily/native";
import { digestHex, stableJson } from "@thriftycrew/domain";
import { generateLegacyConfiguration } from "./config";
import { buildNativeParityReport, compileProductMatcher, evaluateAisleFamilyEvidence, type AisleFamily, type NativeEngineSnapshot } from "@thriftycrew/engine";
import { checkScheduleAuthority, readScheduleAuthority } from "./schedules";
import { checkAgentRegistry, readAgentRegistry } from "./agents";
import { captureQueueStatus, defaultCaptureQueueRoot, drainCaptureQueue, enqueueCapture, PermanentCaptureError, verifyCaptureQueueFilesystem } from "./capture-queue";
import { findLatestRegularCapture, omahaDateKey, parseServerCaptureStore, readFreshRegularCapture, SERVER_CAPTURE_STORES } from "./current-captures";

const platformRoot = path.resolve(import.meta.dirname, "../../..");
const incomeRoot = path.resolve(platformRoot, "..");
const invocationRoot = path.resolve(process.env.INIT_CWD ?? process.cwd());
const [command = "help", subcommand, ...arguments_] = process.argv.slice(2);

function cliPath(file: string): string {
  return path.isAbsolute(file) ? file : path.resolve(invocationRoot, file);
}

async function githubOidcToken(): Promise<string | undefined> {
  if (process.env.TC_OIDC_TOKEN) return process.env.TC_OIDC_TOKEN;
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
  const oidcToken = await githubOidcToken();
  const secret = process.env.TC_LOCAL_MUTATION_SECRET;
  if (!oidcToken && !secret) throw new Error("set TC_LOCAL_MUTATION_SECRET locally or run from a GitHub OIDC-enabled job");
  return new MutationClient({
    origin: process.env.TC_API_ORIGIN ?? "http://127.0.0.1:8787",
    agentId: process.env.TC_AGENT_ID ?? "local-operator",
    ...(oidcToken ? { oidcToken } : { secret }),
  });
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

async function matchBatch(client: MutationClient, batchId: string): Promise<Record<string, unknown>> {
  const snapshot = await client.request(`/internal/capture-batches/${encodeURIComponent(batchId)}/products`) as unknown as Record<string, unknown> & {
    sourceId: string; status: string; configurationId: string; configurationHash: string; products: MatchProductRow[];
  };
  if (!Array.isArray(snapshot.products)) throw new Error("matching snapshot omitted products");
  if (!(snapshot.status === "promoted" || snapshot.status === "validated")) throw new Error(`batch ${batchId} cannot be matched from ${snapshot.status}`);
  const commodities = JSON.parse(await readFile(path.join(platformRoot, "config", "commodities.json"), "utf8")) as Array<{ id: string; include?: string[]; exclude?: string[] }>;
  const categoryDocument = JSON.parse((await readFile(path.join(platformRoot, "config", "categories.json"), "utf8")).replace(/^\uFEFF/, "")) as { categories: Array<{ key: string; commodities: string[] }> };
  const categoryByCommodity = new Map(categoryDocument.categories.flatMap((category) => category.commodities.map((commodityId) => [commodityId, category.key] as const)));
  const nonFoodFamilies = new Set(["household", "personal", "baby", "pet"]);
  const matcher = compileProductMatcher(commodities.map((commodity, index) => ({
    commodityId: commodity.id,
    includes: commodity.include ?? [],
    excludes: commodity.exclude ?? [],
    // Preserve the production engine's documented first-match-wins semantics
    // while making the precedence explicit and collision-testable.
    priority: commodities.length - index,
  })));
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
  for (let offset = 0; offset < decisions.length; offset += 100) {
    await client.request("/internal/match-decisions", { method: "PUT", json: { decisions: decisions.slice(offset, offset + 100) } });
  }
  await client.request("/internal/match-decisions/reconcile", { json: {
    batchId,
    configurationId: snapshot.configurationId,
    retainedProductIds: decisions.map((decision) => decision.productId),
  } });
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
    },
  };
  const persisted = await client.request("/internal/match-runs", { method: "POST", json: report, acceptStatuses: [422] });
  return { ...persisted, ...report };
}

async function rematchPromotedBatches(client: MutationClient): Promise<{ ok: boolean; batches: Array<Record<string, unknown>> }> {
  const listed = await client.request("/internal/capture-batches/promoted") as { batches?: Array<{ id: string; source_id: string; captured_to: string }> };
  const batches: Array<Record<string, unknown>> = [];
  for (const batch of listed.batches ?? []) {
    const matching = await matchBatch(client, batch.id);
    if (matching.status !== "passed") throw new Error(`promoted batch ${batch.id} failed matching under the active configuration`);
    batches.push({ ...batch, matching });
  }
  return { ok: true, batches };
}

async function commodityAdd(inputFile: string | undefined): Promise<unknown> {
  if (!inputFile) throw new Error("tc commodity add requires a JSON file");
  const incoming = JSON.parse(await readFile(cliPath(inputFile), "utf8")) as { id?: string; label?: string; unit?: string; include?: string[]; exclude?: string[]; categoryId?: string };
  if (!incoming.id || !/^[a-z0-9][a-z0-9-]*$/.test(incoming.id) || !incoming.label || !incoming.unit || !incoming.categoryId) throw new Error("commodity file needs id, label, unit, and categoryId");
  const commodityFile = path.join(platformRoot, "config", "commodities.json");
  const categoryFile = path.join(platformRoot, "config", "categories.json");
  const commodities = JSON.parse(await readFile(commodityFile, "utf8")) as Array<Record<string, unknown>>;
  if (commodities.some((item) => item.id === incoming.id)) throw new Error(`commodity ${incoming.id} already exists`);
  commodities.push({ id: incoming.id, label: incoming.label, unit: incoming.unit, include: incoming.include ?? [], exclude: incoming.exclude ?? [] });
  const categoryDocument = JSON.parse(await readFile(categoryFile, "utf8")) as { categories: Array<{ key: string; commodities: string[] }> };
  const category = categoryDocument.categories.find((item) => item.key === incoming.categoryId);
  if (!category) throw new Error(`category ${incoming.categoryId} does not exist`);
  category.commodities.push(incoming.id);
  await writeJson(commodityFile, commodities);
  await writeJson(categoryFile, categoryDocument);
  return generateLegacyConfiguration(incomeRoot, false);
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
  const snapshot = await client.request("/internal/engine/snapshot?mode=direct") as unknown as NativeEngineSnapshot;
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
  if (subcommand === "run" || subcommand === "reconcile") {
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
    result = await (await mutationClient()).request(`/internal/triage?status=${encodeURIComponent(subcommand ?? "open")}`);
  }
} else if (command === "config" && (subcommand === "generate" || subcommand === "check")) {
  result = await generateLegacyConfiguration(incomeRoot, subcommand === "check");
} else if (command === "config" && subcommand === "deploy") {
  await generateLegacyConfiguration(incomeRoot, true);
  const artifact = await buildCurrentBridge(incomeRoot);
  const client = await mutationClient();
  const deployment = await deployConfiguration(client, artifact.configuration);
  const matching = await rematchPromotedBatches(client);
  result = {
    ok: true,
    configurationId: artifact.configuration.id,
    configurationActivated: deployment.active === true,
    rematched: matching.ok === true,
    releasePublicationRequired: true,
    deployment,
    matching,
  };
} else if (command === "schedules" && subcommand === "check") {
  result = await checkScheduleAuthority(platformRoot);
} else if (command === "schedules" && subcommand === "deploy") {
  const document = await readScheduleAuthority(platformRoot);
  result = await (await mutationClient()).request("/internal/schedules/sync", { method: "PUT", json: document });
} else if (command === "agents" && subcommand === "check") {
  result = await checkAgentRegistry(platformRoot);
} else if (command === "agents" && subcommand === "deploy") {
  await checkAgentRegistry(platformRoot);
  result = await (await mutationClient()).request("/internal/agents/sync", { method: "PUT", json: await readAgentRegistry(platformRoot) });
} else if (command === "backup" && subcommand === "trigger") {
  result = await (await mutationClient()).request(`/internal/backups/trigger${arguments_.includes("--replica") ? "?replica=1" : ""}`, { method: "POST" });
} else if (command === "restore" && subcommand === "record") {
  const file = arguments_[0];
  if (!file) throw new Error("tc restore record requires a JSON evidence file");
  result = await (await mutationClient()).request("/internal/restore-drills", { json: JSON.parse(await readFile(cliPath(file), "utf8")) });
} else if (command === "restore" && subcommand === "show") {
  result = await (await mutationClient()).request("/internal/restore-drills");
} else if (command === "restore" && subcommand === "trigger") {
  result = await (await mutationClient()).request("/internal/restore-drills/trigger", { method: "POST" });
} else if (command === "archive" && subcommand === "plan") {
  const cutoffAt = arguments_.find((value: string) => !value.startsWith("--")) ?? new Date(Date.now() - 18 * 30 * 24 * 60 * 60 * 1000).toISOString();
  result = await (await mutationClient()).request("/internal/archival/plan", { json: { cutoffAt, dryRun: !arguments_.includes("--execute"), maximumRows: 10000 }, acceptStatuses: [409, 422] });
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
  result = await (await mutationClient()).request("/internal/job-runs", { json: {
    id: runId,
    job,
    triggerKind: process.env.GITHUB_RUN_ID ? "schedule" : "operator",
    scheduledFor: process.env.TC_SCHEDULED_FOR ?? now,
    startedAt: now,
    executorRunId: process.env.GITHUB_SERVER_URL && process.env.GITHUB_REPOSITORY && process.env.GITHUB_RUN_ID
      ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}`
      : runId,
    ...(process.env.TC_AGENT_ID ? {
      agentId: process.env.TC_AGENT_ID,
      promptHash: process.env.TC_AGENT_PROMPT_HASH,
      modelId: process.env.TC_AGENT_MODEL,
      ledgerMode: process.env.TC_AGENT_DIAGNOSTIC === "1" ? "diagnostic" : "normal",
      mutationAuthorized: process.env.TC_AGENT_DIAGNOSTIC !== "1",
      estimatedCostMicrousd: Number(process.env.TC_AGENT_ESTIMATED_COST_MICROUSD ?? "0"),
    } : {}),
    input: { reason: process.env.TC_RECOVERY_REASON ?? "scheduled operation" },
  } });
} else if (command === "job" && subcommand === "github-runs") {
  const limit = arguments_[0] ?? "5";
  if (!/^([1-9]|10)$/.test(limit)) throw new Error("tc job github-runs limit must be from 1 through 10");
  result = await (await mutationClient()).request(`/internal/jobs/github-runs?limit=${limit}`);
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
    stats: { githubJobStatus: requested },
    ...(status === "failed" ? { error: `GitHub recovery job ended with ${requested}` } : {}),
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
} else if (command === "engine" && subcommand === "parity") {
  const requestedMode = arguments_[0] ?? "legacy";
  if (!(["legacy", "direct", "all"] as const).includes(requestedMode as "legacy" | "direct" | "all")) throw new Error("tc engine parity mode must be legacy, direct, or all");
  const client = await mutationClient();
  const snapshot = await client.request(`/internal/engine/snapshot?mode=${requestedMode}&profile=parity`) as unknown as NativeEngineSnapshot;
  const report = buildNativeParityReport(snapshot);
  result = await client.request("/internal/engine/parity", { json: report, acceptStatuses: [422] });
} else if (command === "engine" && (subcommand === "build-native" || subcommand === "publish-native")) {
  const client = await mutationClient();
  const snapshot = await client.request("/internal/engine/snapshot?mode=direct") as unknown as NativeEngineSnapshot;
  const artifact = await buildNativeRelease(incomeRoot, snapshot);
  const outputArgument = arguments_.find((value: string) => value.endsWith(".json"));
  if (outputArgument) await writeJson(cliPath(outputArgument), artifact);
  if (Number(artifact.audit.top5Entries) !== 20 || Number(artifact.audit.rotationEntries) !== 20) {
    throw new Error(`native release preflight requires exactly 20 complete ranked recipes; got ${String(artifact.audit.top5Entries)}`);
  }
  result = subcommand === "build-native"
    ? { ok: true, releaseId: artifact.releaseId, inputHash: artifact.inputHash, outputFile: outputArgument ? cliPath(outputArgument) : null, audit: artifact.audit }
    : await publishNativeRelease(client, artifact);
} else if (command === "replay") {
  const artifact = await buildCurrentBridge(incomeRoot);
  result = await replayCurrentArtifact(await mutationClient(), artifact);
} else if (command === "capture" && subcommand === "build-regular") {
  const browser = arguments_.includes("--browser");
  const [store, inputFile, outputFile, attestationFile] = arguments_.filter((value: string) => value !== "--browser");
  if (!store || !inputFile || !outputFile) throw new Error("tc capture build-regular requires store, input file, and output file");
  const source = JSON.parse(await readFile(cliPath(inputFile), "utf8").then((value) => value.replace(/^\uFEFF/, "")));
  const attestation = attestationFile ? JSON.parse(await readFile(cliPath(attestationFile), "utf8")) as CaptureAttestation : undefined;
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
  const ingestion = await ingestDirectCapture(client, artifact, evidenceInputs[0]!.body, evidenceInputs.slice(1));
  const matching = ingestion.ok ? await matchBatch(client, String(ingestion.batchId)) : null;
  result = { ...ingestion, matching };
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
    const artifact = await buildRegularCapture(store, fresh.document);
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
    const ingestion = await ingestDirectCapture(client, artifact, new Uint8Array(await readFile(file)));
    if (!ingestion.ok) throw new Error(`current ${store} capture was rejected: ${stableJson(ingestion)}`);
    const matching = await matchBatch(client, String(ingestion.batchId));
    captures.push({ store, file, newestCaptureDate: fresh.newestCaptureDate, oldestCaptureDate: fresh.oldestCaptureDate, sourceRows: fresh.rows, sentinel: sentinelReceipt, ...ingestion, matching });
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
    const artifact = await buildRegularCapture(store, fresh.document);
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
  result = await rematchPromotedBatches(await mutationClient());
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
    if (!artifactFile) throw new Error("tc capture queue enqueue requires an artifact file and screenshot evidence");
    result = await enqueueCapture(root, cliPath(artifactFile), evidenceFiles.map(cliPath));
  } else if (action === "drain") {
    const client = await mutationClient();
    const drained = await drainCaptureQueue(root, async (job) => {
      const artifactBody = new Uint8Array(await readFile(job.artifactPath));
      const additionalEvidence: CaptureEvidenceInput[] = await Promise.all(job.evidencePaths.map(async (evidence) => ({
        body: new Uint8Array(await readFile(evidence.path)),
        kind: evidence.kind,
        contentType: evidence.contentType,
      })));
      const ingestion = await ingestDirectCapture(client, job.artifact, artifactBody, additionalEvidence, { promote: false });
      if (!ingestion.ok) throw new PermanentCaptureError(`capture batch ${String(ingestion.batchId)} was rejected: ${stableJson(ingestion)}`);
      return ingestion;
    });
    result = drained;
    if (!drained.ok) process.exitCode = 2;
  } else if (action === "status" || action === "watchdog") {
    const filesystem = await verifyCaptureQueueFilesystem(root);
    const status = await captureQueueStatus(root, {
      maxPendingMinutes: Number(process.env.TC_CAPTURE_QUEUE_MAX_PENDING_MINUTES ?? 180),
      maxAttempts: Number(process.env.TC_CAPTURE_QUEUE_MAX_ATTEMPTS ?? 5),
    });
    const queueResult = { ...status, filesystem };
    result = queueResult;
    if (action === "watchdog") {
      const alert = await (await mutationClient()).request("/internal/operational-alerts", { json: {
        key: "pc-browser-capture-queue",
        title: "PC browser capture queue is not draining",
        status: status.ok ? "resolved" : "firing",
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
        },
      } });
      result = { ...queueResult, alert };
      if (!status.ok) process.exitCode = 2;
    }
  } else {
    throw new Error("tc capture queue requires enqueue, drain, status, or watchdog");
  }
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
} else if (command === "recipe" && subcommand === "add") {
  result = await recipeAdd(arguments_[0]);
} else {
  const requestedCommand = [command, subcommand, ...arguments_].filter(Boolean).join(" ");
  const isHelpRequest = command === "help" && subcommand === undefined && arguments_.length === 0;
  result = {
    ok: isHelpRequest,
    ...(!isHelpRequest ? { error: `Unknown command: ${requestedCommand}` } : {}),
    usage: [
      "tc status", "tc doctor", "tc triage [status|run|reconcile]", "tc triage review <id> <file>|plan|resolve|needs-operator <id> <file>", "tc config generate|check|deploy",
      "tc schedules check|deploy", "tc agents check|deploy", "tc content show|create <json>|items <batch> <json>|audit <batch> <json>|promote <batch>", "tc backup trigger [--replica]", "tc restore trigger|record <file>|show", "tc archive plan [cutoff] [--execute]|export <manifest> <json>|upload <manifest> <parquet>", "tc evidence record <file>|show [gate]|accrue", "tc entitlement record <file>|show", "tc drill release-freeze|ghost-clobber [release-id]|chaos <kind>|stale-capture [artifact]", "tc job start|finish|dispatch <job> [status|reason]|github-runs [limit]",
      "tc ghost reconcile [release-id]",
        "tc run daily --dry", "tc parity", "tc replay", "tc engine parity [legacy|direct|all]", "tc capture validate|ingest <file> [evidence]", "tc capture build-regular <store> <input> <output> [attestation] [--browser]",
      "tc capture queue enqueue <artifact> <screenshot...>", "tc capture queue drain|status|watchdog",
      "tc capture ingest-current [bakers family-fare hy-vee]|promote-ready-browser|rematch-promoted|abandon <batch-id> <reason>",
      "tc accuracy draw [seed]", "tc accuracy show [draw-id] [--reveal]", "tc accuracy verdict <file>",
      "tc sentinel latest [bakers family-fare hy-vee]",
      "tc match batch <batch-id>", "tc commodity add <file>", "tc recipe add <file>",
    ],
  };
  if (!isHelpRequest) process.exitCode = 2;
}

console.log(JSON.stringify(result, null, 2));
