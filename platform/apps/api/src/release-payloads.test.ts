import { describe, expect, it } from "vitest";
import { releasePayloadObjectKey } from "./release-payloads";

describe("release payload object identity", () => {
  it("keeps identical immutable payload bytes isolated by release", () => {
    const hash = "a".repeat(64);
    expect(releasePayloadObjectKey("rel_one", "board", hash)).not.toBe(releasePayloadObjectKey("rel_two", "board", hash));
    expect(releasePayloadObjectKey("rel_one", "board", hash)).toContain("release=rel_one/kind=board");
    expect(releasePayloadObjectKey("rel_one", "top5", hash)).toContain("kind=top5");
  });

  it("rejects unsafe key material", () => {
    expect(() => releasePayloadObjectKey("../release", "board", "a".repeat(64))).toThrow(/safe release id/);
    expect(() => releasePayloadObjectKey("rel_one", "board", "bad")).toThrow(/SHA-256/);
  });
});
