import { describe, expect, it } from "vitest";
import { agentJobRunFields } from "./job-run";

describe("job-run agent metadata", () => {
  it("does not misclassify the local operator authentication identity as an AI agent run", () => {
    expect(agentJobRunFields({ TC_AGENT_ID: "local-operator" })).toBeUndefined();
  });

  it("includes complete agent execution metadata", () => {
    expect(agentJobRunFields({
      TC_AGENT_ID: "triage-reviewer",
      TC_AGENT_PROMPT_HASH: "prompt-hash",
      TC_AGENT_MODEL: "gpt-5.6-sol",
      TC_AGENT_DIAGNOSTIC: "1",
      TC_AGENT_ESTIMATED_COST_MICROUSD: "1200",
    })).toEqual({
      agentId: "triage-reviewer",
      promptHash: "prompt-hash",
      modelId: "gpt-5.6-sol",
      ledgerMode: "diagnostic",
      mutationAuthorized: false,
      estimatedCostMicrousd: 1200,
    });
  });
});
