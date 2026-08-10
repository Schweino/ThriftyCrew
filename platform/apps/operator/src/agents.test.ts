import { describe, expect, it } from "vitest";
import path from "node:path";
import { agentRegistryEntrySchema } from "@thriftycrew/contracts";
import { checkAgentRegistry } from "./agents";

describe("agent registry", () => {
  it("matches every deployed prompt hash and fixture", async () => {
    const platformRoot = path.resolve(import.meta.dirname, "../../..");
    await expect(checkAgentRegistry(platformRoot)).resolves.toMatchObject({ ok: true, enabled: 10, pc: 0 });
  });

  it("rejects a PC judgment agent with content mutation", () => {
    expect(() => agentRegistryEntrySchema.parse({
      id: "bad-pc-agent", enabled: true, plane: "pc", promptFile: "agents/bad/prompt.md",
      promptSha256: "a".repeat(64), model: "fixture", monthlyBudgetMicrousd: 1,
      criticality: "optional", capabilities: ["write:content-stage"], inputContracts: ["input"],
      outputContract: "output", fixtureFiles: ["fixture.json"],
    })).toThrow(/PC agents may only write/);
  });
});
