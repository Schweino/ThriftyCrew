import { describe, expect, it } from "vitest";
import path from "node:path";
import { agentRegistryEntrySchema } from "@thriftycrew/contracts";
import { normalizeTextForHash } from "@thriftycrew/domain";
import { checkAgentRegistry, executionConfigHash } from "./agents";

describe("agent registry", () => {
  it("matches every deployed prompt hash and fixture", async () => {
    const platformRoot = path.resolve(import.meta.dirname, "../../..");
    await expect(checkAgentRegistry(platformRoot)).resolves.toMatchObject({ ok: true, enabled: 10, pc: 10 });
  });

  it("permits a registered PC judgment agent while preserving capability incompatibilities", () => {
    expect(() => agentRegistryEntrySchema.parse({
      id: "pc-content-agent", enabled: true, plane: "pc", promptFile: "agents/content/prompt.md",
      promptSha256: "a".repeat(64), provider: "openai", model: "fixture", reasoningEffort: "medium", monthlyBudgetMicrousd: 1,
      reserveBudgetPercent: 0, criticality: "optional", workflowFile: ".github/workflows/a.yml",
      reusableWorkflowFile: ".github/workflows/runner.yml", executionConfigHash: "b".repeat(64),
      capabilities: ["write:content-stage"], inputContracts: ["input"], outputContract: "output", fixtureFiles: ["fixture.json"],
    })).not.toThrow();
  });

  it("hashes execution semantics but not schedule or budget plumbing", () => {
    const semantic = {
      provider: "openai", model: "gpt-5.6-terra", fallbackModel: "gpt-5.6-luna", reasoningEffort: "medium",
      promptSha256: "a".repeat(64), inputContracts: ["input-v1"], outputContract: "output-v1",
      capabilities: ["write:ledger"],
    };
    const first = executionConfigHash(semantic);
    expect(executionConfigHash({ ...semantic, monthlyBudgetMicrousd: 1, scheduleId: "one" } as typeof semantic)).toBe(first);
    expect(executionConfigHash({ ...semantic, promptSha256: "b".repeat(64) })).not.toBe(first);
  });

  it("normalizes prompt line endings before hashing", () => {
    expect(normalizeTextForHash("first\r\nsecond\rthird\n")).toBe("first\nsecond\nthird\n");
  });
});
