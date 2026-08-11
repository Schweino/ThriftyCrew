export type AgentJobRunFields = {
  agentId: string;
  promptHash: string;
  modelId: string;
  ledgerMode: "diagnostic" | "normal";
  mutationAuthorized: boolean;
  estimatedCostMicrousd: number;
};

export function agentJobRunFields(environment: Record<string, string | undefined>): AgentJobRunFields | undefined {
  const agentId = environment.TC_AGENT_ID;
  const promptHash = environment.TC_AGENT_PROMPT_HASH;
  const modelId = environment.TC_AGENT_MODEL;
  if (!agentId || !promptHash || !modelId) return undefined;
  const diagnostic = environment.TC_AGENT_DIAGNOSTIC === "1";
  return {
    agentId,
    promptHash,
    modelId,
    ledgerMode: diagnostic ? "diagnostic" : "normal",
    mutationAuthorized: !diagnostic,
    estimatedCostMicrousd: Number(environment.TC_AGENT_ESTIMATED_COST_MICROUSD ?? "0"),
  };
}
