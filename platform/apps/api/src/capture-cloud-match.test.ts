import { describe, expect, it } from "vitest";
import { assertCaptureConfigurationPin } from "./capture-cloud-match";
import type { WorkerEnv } from "./env";

function environment(contentHash: string | null) {
  return {
    DB: {
      prepare: () => ({ bind: () => ({ first: async () => contentHash === null ? null : { content_hash: contentHash } }) }),
    },
  } as unknown as WorkerEnv;
}

describe("cloud capture configuration pin", () => {
  it("accepts the exact sealed configuration identity and content hash", async () => {
    await expect(assertCaptureConfigurationPin(environment("hash-1"), {
      configurationId: "config-1", configurationHash: "hash-1",
    })).resolves.toBeUndefined();
  });

  it("fails closed if pinned configuration content changes or disappears", async () => {
    await expect(assertCaptureConfigurationPin(environment("hash-2"), {
      configurationId: "config-1", configurationHash: "hash-1",
    })).rejects.toThrow("content hash changed");
    await expect(assertCaptureConfigurationPin(environment(null), {
      configurationId: "config-1", configurationHash: "hash-1",
    })).rejects.toThrow("is missing");
  });
});
