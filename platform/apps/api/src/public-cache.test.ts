import { describe, expect, it } from "vitest";
import { cachedPublicJson, releaseEtag } from "./public-cache";

describe("public release cache", () => {
  it("creates a strong content-addressed ETag", () => {
    expect(releaseEtag("a".repeat(64))).toBe(`"sha256-${"a".repeat(64)}"`);
  });

  it("returns 304 for the exact current content hash", async () => {
    const etag = releaseEtag("b".repeat(64));
    const response = await cachedPublicJson(new Request("https://example.com/api/v2/board", {
      headers: { "if-none-match": etag },
    }), async () => ({ body: { ok: true }, etag, releaseId: "release" }));
    expect(response.status).toBe(304);
    expect(response.headers.get("etag")).toBe(etag);
    expect(response.headers.get("x-release-id")).toBe("release");
  });
});

