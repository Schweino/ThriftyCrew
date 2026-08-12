import { describe, expect, it } from "vitest";
import { digestHex, stableJson } from "@thriftycrew/domain";
import { summarizeBrowserCaptureSession, validateBrowserCaptureEvidence, validateScreenshotEvidence } from "./evidence-validation";

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
      worklistHash: "c".repeat(64), startedAt: "2026-08-11T15:00:00.000Z", finishedAt: "2026-08-11T15:02:00.000Z",
      coverageMode: "full" as const, expectedTerms: 1,
      terms: [{ termKey: "eggs", query: "eggs", ordinal: 0, outcome: "success" as const, rowCount: 1, attempts: 1, startedAt: "2026-08-11T15:00:00.000Z", finishedAt: "2026-08-11T15:01:00.000Z" }],
      canaries: [{ ordinal: 0, observedAt: "2026-08-11T15:00:00.000Z", market: "Omaha", location: "Omaha L St Supercenter", priceMode: "pickup", evidenceUrl: "https://www.walmart.com/", marketVerified: true as const, locationVerified: true as const, priceModeVerified: true as const, screenshotSha256: screenshotHash }],
      chunks: [{ id: "chunk-fixture", ordinal: 0, termKeys: ["eggs"], rowCount: 1, sha256: "d".repeat(64), createdAt: "2026-08-11T15:01:00.000Z" }],
      projectedCaptureSha256: rawHash,
    };
    const session = { ...content, contentHash: await digestHex(stableJson(content)) };
    const bucket = { async get(key: string) { return key === "manifest" ? { async text() { return JSON.stringify(session); } } : null; } } as unknown as R2Bucket;
    const rows = [{ object_key: "manifest", kind: "manifest", sha256: "e".repeat(64) }, { object_key: "raw", kind: "raw_payload", sha256: rawHash }, { object_key: "proof", kind: "screenshot", sha256: screenshotHash }];
    const result = await validateBrowserCaptureEvidence(bucket, { sourceId: content.sourceId, coverageMode: "full", capturedFrom: content.startedAt, capturedTo: content.finishedAt, expectedTerms: 1 }, rows);
    expect(result).toMatchObject({ pass: true, detail: { contentHashPass: true, screenshotBound: true, rawBound: true, identityPass: true } });
    expect(result.metrics).toMatchObject({ cycleStart: "2026-08-05", durationMs: 120_000, termDurationP50Ms: 60_000, termDurationP95Ms: 60_000, retryCount: 0, projectedRows: 1 });
    expect((await validateBrowserCaptureEvidence(bucket, { sourceId: content.sourceId, coverageMode: "partial", capturedFrom: content.startedAt, capturedTo: content.finishedAt, expectedTerms: 1 }, rows)).pass).toBe(false);
  });

  it("summarizes retries and percentile durations without storing term-level payloads", async () => {
    const session = {
      version: 1 as const, sessionId: "browser-aldi-metrics", store: "aldi" as const, sourceId: "direct-aldi-browser",
      worklistHash: "a".repeat(64), startedAt: "2026-08-12T14:00:00.000Z", finishedAt: "2026-08-12T14:10:00.000Z",
      coverageMode: "partial" as const, expectedTerms: 3,
      terms: [
        { termKey: "a", query: "a", ordinal: 0, outcome: "success" as const, rowCount: 2, attempts: 2, startedAt: "2026-08-12T14:00:00.000Z", finishedAt: "2026-08-12T14:01:00.000Z" },
        { termKey: "b", query: "b", ordinal: 1, outcome: "blocked" as const, rowCount: 0, attempts: 1, reason: "challenge", startedAt: "2026-08-12T14:01:00.000Z", finishedAt: "2026-08-12T14:05:00.000Z" },
        { termKey: "c", query: "c", ordinal: 2, outcome: "not_attempted" as const, rowCount: 0, attempts: 3, reason: "stopped", startedAt: "2026-08-12T14:00:00.000Z", finishedAt: "2026-08-12T14:00:00.000Z" },
      ],
      canaries: [{ ordinal: 0, observedAt: "2026-08-12T14:00:00.000Z", market: "Omaha", location: "ALDI OLA 42 Omaha", priceMode: "in-store", evidenceUrl: "https://aldi.us", marketVerified: true as const, locationVerified: true as const, priceModeVerified: true as const, screenshotSha256: "b".repeat(64) }],
      chunks: [{ id: "chunk", ordinal: 0, termKeys: ["a", "b"], rowCount: 2, sha256: "c".repeat(64), createdAt: "2026-08-12T14:05:00.000Z" }],
      projectedCaptureSha256: "d".repeat(64), contentHash: "e".repeat(64),
    };
    expect(summarizeBrowserCaptureSession(session)).toMatchObject({ attemptedTerms: 2, successTerms: 1, blockedTerms: 1, notAttemptedTerms: 1, retryCount: 1, termDurationP50Ms: 60_000, termDurationP95Ms: 240_000, projectedRows: 2 });
  });

  it("validates a compact authenticated PC attestation without loading the large manifest", async () => {
    const manifestHash = "a".repeat(64);
    const rawHash = "b".repeat(64);
    const screenshotHash = "c".repeat(64);
    const termsHash = "d".repeat(64);
    const bucket = { async get() { throw new Error("large manifest must not be loaded"); } } as unknown as R2Bucket;
    const batch = {
      sourceId: "direct-walmart-browser", coverageMode: "full", expectedTerms: 1,
      capturedFrom: "2026-08-11T15:00:00.000Z", capturedTo: "2026-08-11T15:02:00.000Z",
    };
    const attestation = {
      version: 1 as const, verifier: "pc-browser-capture-queue" as const, verifiedAt: "2026-08-11T15:03:00.000Z",
      sessionId: "browser-walmart-fixture", sessionVersion: 2 as const, sourceId: batch.sourceId, store: "walmart" as const,
      coverageMode: "full" as const, startedAt: batch.capturedFrom, finishedAt: batch.capturedTo, expectedTerms: 1,
      captureTermsSha256: termsHash, sessionContentHash: "e".repeat(64), manifestSha256: manifestHash,
      projectedCaptureSha256: rawHash, screenshotSha256: screenshotHash,
      dailyShards: [{ date: "2026-08-11", ordinal: 0, contentHash: "f".repeat(64), termCount: 1, rowCount: 3, chunkCount: 2, firstObservedAt: batch.capturedFrom, lastObservedAt: batch.capturedTo }],
      offerConfirmations: [{ productKey: "123", discoveryHash: "1".repeat(64), purchasePriceMinor: 199, discoveredAt: "2026-08-11T15:01:00.000Z", confirmedAt: "2026-08-11T15:01:30.000Z" }],
      metrics: {
        cycleStart: "2026-08-05", attemptedTerms: 1, successTerms: 1, emptyTerms: 0, rejectedTerms: 0,
        blockedTerms: 0, notAttemptedTerms: 0, retryCount: 0, chunkCount: 2, durationMs: 120_000,
        termDurationP50Ms: 60_000, termDurationP95Ms: 60_000, projectedRows: 3, accuracyPolicyVersion: 2 as const,
        discoveryRows: 3, requiredVerificationRows: 1, matchedVerificationRows: 1, unresolvedVerificationRows: 0,
        priceAgreementRows: 3, singleChannelRows: 0, anomalyRows: 0, retrievalCompleteTerms: 1,
        pageStateAttestedRows: 3, promotionSemanticsRows: 3,
        dailyShardCount: 1, likelyWinnerRows: 1, confirmedWinnerRows: 1,
      },
    };
    const rows = [
      { object_key: "manifest", kind: "manifest", sha256: manifestHash },
      { object_key: "raw", kind: "raw_payload", sha256: rawHash },
      { object_key: "proof", kind: "screenshot", sha256: screenshotHash },
    ];
    const result = await validateBrowserCaptureEvidence(bucket, batch, rows, attestation, termsHash);
    expect(result).toMatchObject({ pass: true, detail: { verificationPlane: "authenticated-pc-browser-capture-agent", manifestBound: true, termsBound: true, accuracyPass: true }, metrics: { discoveryRows: 3 } });
    const legacyAccuracyAttestation = { ...attestation, metrics: { ...attestation.metrics, accuracyPolicyVersion: 1 as const, pageStateAttestedRows: 0, promotionSemanticsRows: 0 } };
    expect((await validateBrowserCaptureEvidence(bucket, batch, rows, legacyAccuracyAttestation, termsHash)).pass).toBe(true);
    expect((await validateBrowserCaptureEvidence(bucket, batch, rows, { ...attestation, manifestSha256: "f".repeat(64) }, termsHash)).pass).toBe(false);
  });
});
