import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { directCaptureArtifactSchema, observationChunkSchema } from "@thriftycrew/contracts";
import { ingestDirectCapture, MutationClient, replayCurrentArtifact, type CaptureEvidenceInput } from "@thriftycrew/daily/client";
import { buildCurrentBridge } from "@thriftycrew/daily/legacy";
import { buildRegularCapture, type CaptureAttestation } from "@thriftycrew/daily/direct";
import { digestHex, stableJson } from "@thriftycrew/domain";
import { generateLegacyConfiguration } from "./config";
import { buildNativeParityReport, compileProductMatcher, evaluateAisleFamilyEvidence, type AisleFamily, type NativeEngineSnapshot } from "@thriftycrew/engine";
import { checkScheduleAuthority, readScheduleAuthority } from "./schedules";

const platformRoot = path.resolve(import.meta.dirname, "../../..");
const incomeRoot = path.resolve(platformRoot, "..");
const [command = "help", subcommand, ...arguments_] = process.argv.slice(2);

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

async function commodityAdd(inputFile: string | undefined): Promise<unknown> {
  if (!inputFile) throw new Error("tc commodity add requires a JSON file");
  const incoming = JSON.parse(await readFile(path.resolve(inputFile), "utf8")) as { id?: string; label?: string; unit?: string; include?: string[]; exclude?: string[]; categoryId?: string };
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
  const specification = JSON.parse(await readFile(path.resolve(inputFile), "utf8")) as { slug?: string; servings?: number; ingredients_grams?: unknown[] };
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

let result: unknown;
if (command === "status") {
  result = await publicGet("/api/v2/status");
} else if (command === "doctor") {
  result = await (await mutationClient()).request("/internal/doctor", { acceptStatuses: [422] });
} else if (command === "triage") {
  result = subcommand === "run"
    ? await (await mutationClient()).request("/internal/triage/run", { method: "POST" })
    : await (await mutationClient()).request(`/internal/triage?status=${encodeURIComponent(subcommand ?? "open")}`);
} else if (command === "config" && (subcommand === "generate" || subcommand === "check")) {
  result = await generateLegacyConfiguration(incomeRoot, subcommand === "check");
} else if (command === "schedules" && subcommand === "check") {
  result = await checkScheduleAuthority(platformRoot);
} else if (command === "schedules" && subcommand === "deploy") {
  const document = await readScheduleAuthority(platformRoot);
  result = await (await mutationClient()).request("/internal/schedules/sync", { method: "PUT", json: document });
} else if (command === "backup" && subcommand === "trigger") {
  result = await (await mutationClient()).request(`/internal/backups/trigger${arguments_.includes("--replica") ? "?replica=1" : ""}`, { method: "POST" });
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
    input: { reason: process.env.TC_RECOVERY_REASON ?? "scheduled operation" },
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
  result = await (await mutationClient()).request(`/internal/job-runs/${githubRunId(job)}`, { method: "PATCH", json: {
    status,
    heartbeatAt: now,
    finishedAt: now,
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
  const snapshot = await client.request(`/internal/engine/snapshot?mode=${requestedMode}`) as unknown as NativeEngineSnapshot;
  const report = buildNativeParityReport(snapshot);
  result = await client.request("/internal/engine/parity", { json: report, acceptStatuses: [422] });
} else if (command === "replay") {
  const artifact = await buildCurrentBridge(incomeRoot);
  result = await replayCurrentArtifact(await mutationClient(), artifact);
} else if (command === "capture" && subcommand === "build-regular") {
  const [store, inputFile, outputFile, attestationFile] = arguments_;
  if (!store || !inputFile || !outputFile) throw new Error("tc capture build-regular requires store, input file, and output file");
  const source = JSON.parse(await readFile(path.resolve(inputFile), "utf8").then((value) => value.replace(/^\uFEFF/, "")));
  const attestation = attestationFile ? JSON.parse(await readFile(path.resolve(attestationFile), "utf8")) as CaptureAttestation : undefined;
  const artifact = await buildRegularCapture(store, source, attestation);
  await writeJson(path.resolve(outputFile), artifact);
  result = { ok: true, outputFile: path.resolve(outputFile), sourceId: artifact.sourceId, observations: artifact.observations.length, terms: artifact.terms.length, audit: artifact.audit };
} else if (command === "capture" && subcommand === "ingest") {
  const [artifactFile, ...evidenceFiles] = arguments_;
  if (!artifactFile) throw new Error("tc capture ingest requires an artifact file");
  const artifactBytes = await readFile(path.resolve(artifactFile));
  const artifact = directCaptureArtifactSchema.parse(JSON.parse(new TextDecoder().decode(artifactBytes).replace(/^\uFEFF/, "")));
  const selectedEvidenceFiles = evidenceFiles.length > 0 ? evidenceFiles : [artifactFile];
  const evidenceInputs: CaptureEvidenceInput[] = await Promise.all(selectedEvidenceFiles.map(async (file: string, index: number) => {
    const extension = path.extname(file).toLowerCase();
    const screenshot = [".png", ".jpg", ".jpeg", ".webp"].includes(extension);
    return {
      body: new Uint8Array(await readFile(path.resolve(file))),
      kind: screenshot ? "screenshot" : index === 0 ? artifact.evidence?.kind ?? "raw_payload" : "manifest",
      contentType: extension === ".png" ? "image/png" : extension === ".jpg" || extension === ".jpeg" ? "image/jpeg" : extension === ".webp" ? "image/webp" : "application/json",
    };
  }));
  const client = await mutationClient();
  const ingestion = await ingestDirectCapture(client, artifact, evidenceInputs[0]!.body, evidenceInputs.slice(1));
  const matching = ingestion.ok ? await matchBatch(client, String(ingestion.batchId)) : null;
  result = { ...ingestion, matching };
} else if (command === "match" && subcommand === "batch") {
  const batchId = arguments_[0];
  if (!batchId) throw new Error("tc match batch requires a capture batch id");
  result = await matchBatch(await mutationClient(), batchId);
} else if (command === "capture" && subcommand === "validate") {
  const file = arguments_[0];
  if (!file) throw new Error("tc capture validate requires a JSON file");
  const parsed = JSON.parse(await readFile(path.resolve(file), "utf8"));
  const direct = directCaptureArtifactSchema.safeParse(parsed);
  result = direct.success
    ? { ok: true, kind: "direct-capture", sourceId: direct.data.sourceId, observations: direct.data.observations.length, terms: direct.data.terms.length, audit: direct.data.audit }
    : { ok: true, kind: "observation-chunk", observations: observationChunkSchema.parse(Array.isArray(parsed) ? { observations: parsed } : parsed).observations.length };
} else if (command === "accuracy" && subcommand === "draw") {
  const now = new Date();
  const due = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000);
  result = await (await mutationClient()).request("/internal/accuracy/draws", { json: { marketId: "omaha", seed: arguments_[0] ?? `week-${now.toISOString().slice(0, 10)}`, protocolVersion: "blind-cell-v1", sampleSize: 100, dueAt: due.toISOString() } });
} else if (command === "accuracy" && subcommand === "show") {
  result = await (await mutationClient()).request(`/internal/accuracy/draw${arguments_[0] ? `?id=${encodeURIComponent(arguments_[0])}` : ""}`);
} else if (command === "accuracy" && subcommand === "verdict") {
  const file = arguments_[0];
  if (!file) throw new Error("tc accuracy verdict requires a JSON file");
  result = await (await mutationClient()).request("/internal/accuracy/verdicts", { json: JSON.parse(await readFile(path.resolve(file), "utf8")) });
} else if (command === "commodity" && subcommand === "add") {
  result = await commodityAdd(arguments_[0]);
} else if (command === "recipe" && subcommand === "add") {
  result = await recipeAdd(arguments_[0]);
} else {
  result = {
    ok: true,
    usage: [
      "tc status", "tc doctor", "tc triage [status|run]", "tc config generate|check",
      "tc schedules check|deploy", "tc backup trigger [--replica]", "tc job start|finish|dispatch <job> [status|reason]",
      "tc ghost reconcile [release-id]",
        "tc run daily --dry", "tc parity", "tc replay", "tc engine parity [legacy|direct|all]", "tc capture validate|ingest <file> [evidence]", "tc capture build-regular <store> <input> <output>",
      "tc accuracy draw [seed]", "tc accuracy show [draw-id]", "tc accuracy verdict <file>",
      "tc match batch <batch-id>", "tc commodity add <file>", "tc recipe add <file>",
    ],
  };
}

console.log(JSON.stringify(result, null, 2));
