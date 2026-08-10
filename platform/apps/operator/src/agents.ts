import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { agentRegistrySchema } from "@thriftycrew/contracts";
import { readScheduleAuthority } from "./schedules";

export async function readAgentRegistry(platformRoot: string) {
  return agentRegistrySchema.parse(JSON.parse(await readFile(path.join(platformRoot, "config", "agents.json"), "utf8")));
}

export async function checkAgentRegistry(platformRoot: string): Promise<Record<string, unknown>> {
  const [registry, schedules] = await Promise.all([readAgentRegistry(platformRoot), readScheduleAuthority(platformRoot)]);
  const scheduleIds = new Set(schedules.schedules.map((schedule) => schedule.id));
  const hashes: Record<string, string> = {};
  for (const agent of registry.agents) {
    if (agent.scheduleId && !scheduleIds.has(agent.scheduleId)) throw new Error(`agent ${agent.id} references unknown schedule ${agent.scheduleId}`);
    const prompt = await readFile(path.join(platformRoot, agent.promptFile));
    const actualHash = createHash("sha256").update(prompt).digest("hex");
    if (actualHash !== agent.promptSha256) throw new Error(`agent ${agent.id} prompt drift: registry ${agent.promptSha256}, actual ${actualHash}`);
    hashes[agent.id] = actualHash;
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
  };
}
