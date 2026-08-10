import { describe, expect, it, vi } from "vitest";
import type { CurrentBridgeArtifact } from "./legacy";
import { deployConfiguration, type MutationClient } from "./client";

describe("configuration deployment", () => {
  it("reports an already-active configuration without laundering a temporary doctor failure", async () => {
    const request = vi.fn().mockResolvedValue({ ok: true, id: "cfg_test", active: true, httpStatus: 200 });
    const client = { request } as unknown as MutationClient;
    const configuration = {
      id: "cfg_test",
      sourceCommit: "test",
      contentHash: "a".repeat(64),
      categories: [],
      commodities: [],
      knownWrong: [],
    } as unknown as CurrentBridgeArtifact["configuration"];

    await expect(deployConfiguration(client, configuration)).resolves.toEqual({
      ok: true,
      configurationId: "cfg_test",
      active: true,
      idempotent: true,
      activation: null,
    });
    expect(request).toHaveBeenCalledTimes(1);
    expect(request).not.toHaveBeenCalledWith("/internal/doctor", expect.anything());
  });
});
