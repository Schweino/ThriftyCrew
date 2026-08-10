import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { agentRegistrySchema } from "@thriftycrew/contracts";
import { readScheduleAuthority } from "./schedules";

export interface AgentExecutionConfiguration {
  provider: string;
  model: string;
  fallbackModel?: string | undefined;
  reasoningEffort: string;
  promptSha256: string;
  inputContracts: string[];
  outputContract: string;
  capabilities: string[];
}

/**
 * Hash only fields that can change an agent's judgment or authority. Scheduling,
 * budgets, fixtures, and workflow plumbing are deliberately excluded so an
 * operational change cannot invalidate evaluation evidence.
 */
export function agentExecutionConfiguration(agent: AgentExecutionConfiguration): AgentExecutionConfiguration {
  return {
    provider: agent.provider,
    model: agent.model,
    ...(agent.fallbackModel ? { fallbackModel: agent.fallbackModel } : {}),
    reasoningEffort: agent.reasoningEffort,
    promptSha256: agent.promptSha256,
    inputContracts: [...agent.inputContracts].sort(),
    outputContract: agent.outputContract,
    capabilities: [...agent.capabilities].sort(),
  };
}

export function executionConfigHash(agent: AgentExecutionConfiguration): string {
  return createHash("sha256").update(JSON.stringify(agentExecutionConfiguration(agent))).digest("hex");
}

export async function readAgentRegistry(platformRoot: string) {
  return agentRegistrySchema.parse(JSON.parse(await readFile(path.join(platformRoot, "config", "agents.json"), "utf8")));
}

export async function checkAgentRegistry(platformRoot: string): Promise<Record<string, unknown>> {
  const [registry, schedules] = await Promise.all([readAgentRegistry(platformRoot), readScheduleAuthority(platformRoot)]);
  const scheduleIds = new Set(schedules.schedules.map((schedule) => schedule.id));
  const hashes: Record<string, string> = {};
  const executionHashes: Record<string, string> = {};
  const workflowFiles = new Set<string>();
  for (const agent of registry.agents) {
    if (agent.scheduleId && !scheduleIds.has(agent.scheduleId)) throw new Error(`agent ${agent.id} references unknown schedule ${agent.scheduleId}`);
    const prompt = await readFile(path.join(platformRoot, agent.promptFile));
    const actualHash = createHash("sha256").update(prompt).digest("hex");
    if (actualHash !== agent.promptSha256) throw new Error(`agent ${agent.id} prompt drift: registry ${agent.promptSha256}, actual ${actualHash}`);
    hashes[agent.id] = actualHash;
    const actualExecutionHash = executionConfigHash(agent);
    if (actualExecutionHash !== agent.executionConfigHash) throw new Error(`agent ${agent.id} execution configuration drift: registry ${agent.executionConfigHash}, actual ${actualExecutionHash}`);
    executionHashes[agent.id] = actualExecutionHash;
    if (workflowFiles.has(agent.workflowFile)) throw new Error(`agent workflow ${agent.workflowFile} is assigned to more than one agent`);
    workflowFiles.add(agent.workflowFile);
    await readFile(path.join(platformRoot, "..", agent.workflowFile));
    await readFile(path.join(platformRoot, "..", agent.reusableWorkflowFile));
    for (const fixture of agent.fixtureFiles) JSON.parse(await readFile(path.join(platformRoot, fixture), "utf8"));
  }
  return {
    ok: true,
    version: registry.version,
    enabled: registry.agents.filter((agent) => agent.enabled).length,
    ci: registry.agents.filter((agent) => agent.plane === "ci").length,
    pc: registry.agents.filter((agent) => agent.plane === "pc").length,
    monthlyBudgetMicrousd: registry.agents.reduce((sum, agent) => sum + agent.monthlyBudgetMicrousd, 0),
    promptHashes: hashes,
    executionConfigHashes: executionHashes,
  };
}
