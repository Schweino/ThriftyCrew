import { describe, expect, it, vi } from "vitest";
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
    expect(response.headers.get("cache-tag")).toBe("grocery-public,grocery-release-release");
  });

  it("evicts a cached error and reloads authoritative release data", async () => {
    const original = Object.getOwnPropertyDescriptor(globalThis, "caches");
    const remove = vi.fn(async () => true);
    const put = vi.fn(async () => undefined);
    Object.defineProperty(globalThis, "caches", { configurable: true, value: { default: {
      match: vi.fn(async () => Response.json({ ok: false }, { status: 500 })), delete: remove, put,
    } } });
    try {
      const response = await cachedPublicJson(new Request("https://example.com/api/v2/recipe-feed/example"), async () => ({
        body: { ok: true }, etag: releaseEtag("c".repeat(64)), releaseId: "fresh-release",
      }));
      expect(response.status).toBe(200);
      expect(response.headers.get("x-release-id")).toBe("fresh-release");
      expect(remove).toHaveBeenCalledOnce();
      expect(put).toHaveBeenCalledOnce();
    } finally {
      if (original) Object.defineProperty(globalThis, "caches", original);
      else Reflect.deleteProperty(globalThis, "caches");
    }
  });
});
