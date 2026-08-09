import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { observationChunkSchema } from "@thriftycrew/contracts";
import { MutationClient, replayCurrentArtifact } from "@thriftycrew/daily/client";
import { buildCurrentBridge } from "@thriftycrew/daily/legacy";
import { generateLegacyConfiguration } from "./config";
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

async function writeJson(file: string, value: unknown): Promise<void> {
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, "utf8");
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
  result = await (await mutationClient()).request(`/internal/triage?status=${encodeURIComponent(subcommand ?? "open")}`);
} else if (command === "config" && (subcommand === "generate" || subcommand === "check")) {
  result = await generateLegacyConfiguration(incomeRoot, subcommand === "check");
} else if (command === "schedules" && subcommand === "check") {
  result = await checkScheduleAuthority(platformRoot);
} else if (command === "schedules" && subcommand === "deploy") {
  const document = await readScheduleAuthority(platformRoot);
  result = await (await mutationClient()).request("/internal/schedules/sync", { method: "PUT", json: document });
} else if (command === "run" && subcommand === "daily" && arguments_.includes("--dry")) {
  const artifact = await buildCurrentBridge(incomeRoot);
  result = { ok: true, dryRun: true, audit: artifact.audit, releaseInputs: artifact.stores.length };
} else if (command === "parity") {
  const artifact = await buildCurrentBridge(incomeRoot);
  result = { ok: artifact.audit.incompleteRecipes === 0 && artifact.audit.uncategorized.length === 0 && artifact.audit.multiplyCategorized.length === 0, audit: artifact.audit };
} else if (command === "replay") {
  const artifact = await buildCurrentBridge(incomeRoot);
  result = await replayCurrentArtifact(await mutationClient(), artifact);
} else if (command === "capture" && subcommand === "validate") {
  const file = arguments_[0];
  if (!file) throw new Error("tc capture validate requires a JSON file");
  const parsed = JSON.parse(await readFile(path.resolve(file), "utf8"));
  result = { ok: true, observations: observationChunkSchema.parse(Array.isArray(parsed) ? { observations: parsed } : parsed).observations.length };
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
      "tc status", "tc doctor", "tc triage [status]", "tc config generate|check",
      "tc schedules check|deploy",
      "tc run daily --dry", "tc parity", "tc replay", "tc capture validate <file>",
      "tc accuracy draw [seed]", "tc accuracy show [draw-id]", "tc accuracy verdict <file>",
      "tc commodity add <file>", "tc recipe add <file>",
    ],
  };
}

console.log(JSON.stringify(result, null, 2));
