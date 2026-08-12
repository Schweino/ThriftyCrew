import { describe, expect, it } from "vitest";
import { digestHex, stableJson } from "@thriftycrew/domain";
import { verifyReleaseGraphTransitive } from "./restore-transitive";

describe("transitive release restore verification", () => {
  it("reads and hashes the manifest and every referenced node", async () => {
    const payload = stableJson({ value: 1 });
    const contentHash = await digestHex(payload);
    const releaseId = "rel_test";
    const manifest = stableJson({ version: 1, releaseId, nodes: [{ kind: "cell", key: "a", contentHash }] });
    const rootHash = await digestHex(manifest);
    const objects = new Map<string, string>([
      [`root/${rootHash}.json`, manifest],
      [`release-nodes/schema=1/kind=cell/prefix=${contentHash.slice(0, 2)}/${contentHash}.json`, payload],
    ]);
    const bucket = { get: async (key: string) => {
      const value = objects.get(key);
      return value === undefined ? null : { arrayBuffer: async () => new TextEncoder().encode(value).buffer };
    } } as unknown as R2Bucket;
    await expect(verifyReleaseGraphTransitive({ ARCHIVE: bucket }, {
      release_id: releaseId, root_hash: rootHash, object_key: `root/${rootHash}.json`, node_count: 1,
    })).resolves.toBe(2);
  });
});
