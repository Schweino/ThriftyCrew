import { describe, expect, it } from "vitest";
import { digestHex, stableJson } from "@thriftycrew/domain";
import { verifyConfigurationArchive } from "./configuration-archive";
import type { WorkerEnv } from "./env";

async function environment(payload: Record<string, unknown>): Promise<{ env: WorkerEnv; bytes: Uint8Array; sha256: string }> {
  const bytes = new TextEncoder().encode(stableJson(payload));
  const sha256 = await digestHex(bytes);
  const env = { ARCHIVE: { get: async () => new Response(bytes) } } as unknown as WorkerEnv;
  return { env, bytes, sha256 };
}

describe("configuration recovery archive v2", () => {
  it("verifies the complete matcher inputs including match priority", async () => {
    const payload = {
      schema: "tc-configuration-archive-v2",
      configuration: { id: "cfg", expected_rules: 1 },
      categories: [],
      commodities: [{ id: "eggs", match_priority: 20 }],
      rules: [{ id: "rule", commodity_id: "eggs", kind: "include", pattern: "egg", reason: "fixture", priority: 0 }],
      knownWrong: [],
    };
    const { env, bytes, sha256 } = await environment(payload);
    const verified = await verifyConfigurationArchive(env, "cfg", "configurations/cfg.json", bytes.byteLength, sha256);
    expect(verified.schemaVersion).toBe(2);
    expect(verified.payload.commodities[0]?.match_priority).toBe(20);
  });

  it("rejects a v2 archive that cannot reproduce matcher precedence", async () => {
    const payload = {
      schema: "tc-configuration-archive-v2",
      configuration: { id: "cfg", expected_rules: 1 },
      categories: [], commodities: [{ id: "eggs" }],
      rules: [{ id: "rule", commodity_id: "eggs", kind: "include", pattern: "egg", reason: "fixture", priority: 0 }],
      knownWrong: [],
    };
    const { env, bytes, sha256 } = await environment(payload);
    await expect(verifyConfigurationArchive(env, "cfg", "configurations/cfg.json", bytes.byteLength, sha256)).rejects.toThrow("match priority");
  });
});
