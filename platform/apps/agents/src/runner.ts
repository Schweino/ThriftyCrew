import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { Agent, run, webSearchTool } from "@openai/agents";
import {
  accuracyVerdictsSchema,
  agentRegistrySchema,
  contentBatchAuditSchema,
  contentBatchItemsSchema,
  pullRequestProposalSchema,
  recipeDedupSchema,
  recipeMapSchema,
  recipeSourceCandidatesSchema,
  triagePlanSchema,
} from "@thriftycrew/contracts";

const platformRoot = path.resolve(import.meta.dirname, "../../..");
const outputRoot = path.resolve(process.env.TC_OUTPUT_ROOT ?? process.env.RUNNER_TEMP ?? path.join(platformRoot, ".agent-output"));
const arguments_ = process.argv.slice(2);
const fixtureMode = arguments_.includes("--fixture");
const requestedAgent = arguments_.find((value) => !value.startsWith("--")) ?? process.env.TC_AGENT_ID;
if (!requestedAgent) throw new Error("agent runner requires an agent id");

const registry = agentRegistrySchema.parse(JSON.parse(await readFile(path.join(platformRoot, "config", "agents.json"), "utf8")));
const definition = registry.agents.find((agent) => agent.id === requestedAgent);
if (!definition || !definition.enabled) throw new Error(`agent ${requestedAgent} is unknown or disabled`);
const activeDefinition = definition;
const runtimePlane = process.env.GITHUB_ACTIONS === "true" ? "ci" : "pc";
if (definition.plane !== runtimePlane && process.env.TC_ALLOW_PLANE_FALLBACK !== "1") {
  throw new Error(`agent ${requestedAgent} is assigned to the ${definition.plane} plane, not ${runtimePlane}`);
}
const prompt = await readFile(path.join(platformRoot, definition.promptFile), "utf8");
const promptHash = createHash("sha256").update(prompt).digest("hex");
if (promptHash !== definition.promptSha256) throw new Error(`agent ${requestedAgent} prompt hash drift`);
const hasApprovedInput = Boolean(process.env.TC_AGENT_INPUT_FILE) || fixtureMode || requestedAgent === "post-publish-reviewer";

async function loadInput(): Promise<unknown> {
  const explicit = process.env.TC_AGENT_INPUT_FILE;
  if (explicit) return JSON.parse(await readFile(path.resolve(explicit), "utf8"));
  if (fixtureMode) return JSON.parse(await readFile(path.join(platformRoot, activeDefinition.fixtureFiles[0]!), "utf8"));
  if (requestedAgent === "post-publish-reviewer") {
    const response = await fetch(new URL("/api/v2/status", process.env.TC_API_ORIGIN ?? "https://www.thriftycrew.com"), { headers: { accept: "application/json", "cache-control": "no-cache" } });
    if (!response.ok) throw new Error(`public status returned ${response.status}`);
    return response.json();
  }
  return { task: requestedAgent, instruction: "No approved mutable input was supplied. Return a typed no-op finding and do not propose publication." };
}

const loadedInput = await loadInput();
const input = requestedAgent === "accuracy-headless" && loadedInput && typeof loadedInput === "object" && !Array.isArray(loadedInput)
  ? { ...(loadedInput as Record<string, unknown>), verificationClock: { startedAt: new Date().toISOString(), timezone: "America/Chicago" } }
  : loadedInput;
const inputJson = JSON.stringify(input);
const inputHash = createHash("sha256").update(inputJson).digest("hex");
await mkdir(outputRoot, { recursive: true });

if (!hasApprovedInput) {
  const diagnostic = { ok: true, skipped: true, reason: "no approved input was supplied", agentId: requestedAgent, promptHash, inputHash };
  await writeFile(path.join(outputRoot, `${requestedAgent}.json`), `${JSON.stringify(diagnostic, null, 2)}\n`, "utf8");
  await writeFile(path.join(outputRoot, `${requestedAgent}-usage.json`), `${JSON.stringify({ inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, costMicrousd: 0 })}\n`, "utf8");
  console.log(JSON.stringify(diagnostic));
  process.exit(0);
}

if (!process.env.OPENAI_API_KEY) {
  const diagnostic = { ok: true, skipped: true, reason: "OPENAI_API_KEY is not configured", agentId: requestedAgent, promptHash, inputHash };
  await writeFile(path.join(outputRoot, `${requestedAgent}.json`), `${JSON.stringify(diagnostic, null, 2)}\n`, "utf8");
  await writeFile(path.join(outputRoot, `${requestedAgent}-usage.json`), `${JSON.stringify({ inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, costMicrousd: 0 })}\n`, "utf8");
  console.log(JSON.stringify(diagnostic));
  process.exit(0);
}

const model = process.env.TC_AGENT_MODEL ?? definition.model;
if (model !== definition.model && model !== definition.fallbackModel) throw new Error(`model ${model} is not registered for ${requestedAgent}`);
const outputSchemas = {
  "triage-plan-v1": triagePlanSchema,
  "pull-request-v1": pullRequestProposalSchema,
  "accuracy-verdicts-v1": accuracyVerdictsSchema,
  "recipe-source-candidates-v1": recipeSourceCandidatesSchema,
  "recipe-dedup-v1": recipeDedupSchema,
  "recipe-map-v1": recipeMapSchema,
  "content-items-v1": contentBatchItemsSchema,
  "content-audit-v1": contentBatchAuditSchema,
} as const;
const outputType = outputSchemas[definition.outputContract as keyof typeof outputSchemas];
if (!outputType) throw new Error(`output contract ${definition.outputContract} has no structured runner schema`);
const agent = new Agent({
  name: requestedAgent,
  instructions: prompt,
  model,
  modelSettings: { reasoning: { effort: definition.reasoningEffort }, text: { verbosity: "low" } },
  tools: requestedAgent === "accuracy-headless"
    ? [webSearchTool({
        searchContextSize: "low",
        externalWebAccess: true,
        userLocation: { type: "approximate", city: "Omaha", region: "Nebraska", country: "US", timezone: "America/Chicago" },
      })]
    : [],
  outputType,
});
const result = await run(agent, inputJson, { maxTurns: 8 });
const usage = result.state.usage;
const prices = registry.pricing[model];
if (!prices) throw new Error(`pricing is unavailable for ${model}`);
const inputTokens = usage.inputTokens;
const outputTokens = usage.outputTokens;
const cacheReadTokens = usage.inputTokensDetails.reduce((sum, details) => sum + (details.cached_tokens ?? details.cachedTokens ?? 0), 0);
const uncachedInputTokens = Math.max(0, inputTokens - cacheReadTokens);
const costMicrousd = Math.ceil(
  uncachedInputTokens * prices.inputMicrousdPerMillion / 1_000_000
  + cacheReadTokens * prices.cacheReadMicrousdPerMillion / 1_000_000
  + outputTokens * prices.outputMicrousdPerMillion / 1_000_000,
);
const output = { ok: true, agentId: requestedAgent, model, promptHash, inputHash, finalOutput: result.finalOutput };
const usageOutput = { inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens: 0, costMicrousd };
await writeFile(path.join(outputRoot, `${requestedAgent}.json`), `${JSON.stringify(output, null, 2)}\n`, "utf8");
await writeFile(path.join(outputRoot, `${requestedAgent}-usage.json`), `${JSON.stringify(usageOutput)}\n`, "utf8");
console.log(JSON.stringify({ ...output, usage: usageOutput }));
