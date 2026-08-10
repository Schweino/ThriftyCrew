import { describe, expect, it } from "vitest";
import { digestHex, stableJson } from "@thriftycrew/domain";
import { validateBrowserCaptureEvidence, validateScreenshotEvidence } from "./evidence-validation";

function png(width: number, height: number, length = 512): Uint8Array {
  const bytes = new Uint8Array(length);
  bytes.set([137, 80, 78, 71, 13, 10, 26, 10], 0);
  bytes.set([73, 72, 68, 82], 12);
  new DataView(bytes.buffer).setUint32(16, width);
  new DataView(bytes.buffer).setUint32(20, height);
  return bytes;
}

describe("browser screenshot evidence", () => {
  it("accepts a plausible browser screenshot", () => {
    expect(validateScreenshotEvidence(png(1280, 720), "image/png")).toEqual({ width: 1280, height: 720 });
  });

  it("rejects extension-only or thumbnail evidence", () => {
    expect(() => validateScreenshotEvidence(new Uint8Array(512), "image/png")).toThrow("invalid PNG");
    expect(() => validateScreenshotEvidence(png(200, 100), "image/png")).toThrow("too small");
  });

  it("binds a full browser session to screenshot and projected raw evidence", async () => {
    const screenshotHash = "a".repeat(64);
    const rawHash = "b".repeat(64);
    const content = {
      version: 1 as const, sessionId: "browser-walmart-fixture", store: "walmart" as const, sourceId: "direct-walmart-browser",
      worklistHash: "c".repeat(64), startedAt: "2026-08-12T15:00:00.000Z", finishedAt: "2026-08-12T15:02:00.000Z",
      coverageMode: "full" as const, expectedTerms: 1,
      terms: [{ termKey: "eggs", query: "eggs", ordinal: 0, outcome: "success" as const, rowCount: 1, attempts: 1, startedAt: "2026-08-12T15:00:00.000Z", finishedAt: "2026-08-12T15:01:00.000Z" }],
      canaries: [{ ordinal: 0, observedAt: "2026-08-12T15:00:00.000Z", market: "Omaha", location: "Omaha L St Supercenter", priceMode: "pickup", evidenceUrl: "https://www.walmart.com/", marketVerified: true as const, locationVerified: true as const, priceModeVerified: true as const, screenshotSha256: screenshotHash }],
      chunks: [{ id: "chunk-fixture", ordinal: 0, termKeys: ["eggs"], rowCount: 1, sha256: "d".repeat(64), createdAt: "2026-08-12T15:01:00.000Z" }],
      projectedCaptureSha256: rawHash,
    };
    const session = { ...content, contentHash: await digestHex(stableJson(content)) };
    const bucket = { async get(key: string) { return key === "manifest" ? { async text() { return JSON.stringify(session); } } : null; } } as unknown as R2Bucket;
    const rows = [{ object_key: "manifest", kind: "manifest", sha256: "e".repeat(64) }, { object_key: "raw", kind: "raw_payload", sha256: rawHash }, { object_key: "proof", kind: "screenshot", sha256: screenshotHash }];
    const result = await validateBrowserCaptureEvidence(bucket, { sourceId: content.sourceId, coverageMode: "full", capturedFrom: content.startedAt, capturedTo: content.finishedAt, expectedTerms: 1 }, rows);
    expect(result).toMatchObject({ pass: true, detail: { contentHashPass: true, screenshotBound: true, rawBound: true, identityPass: true } });
    expect((await validateBrowserCaptureEvidence(bucket, { sourceId: content.sourceId, coverageMode: "partial", capturedFrom: content.startedAt, capturedTo: content.finishedAt, expectedTerms: 1 }, rows)).pass).toBe(false);
  });
});
