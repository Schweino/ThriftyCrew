import { browserCaptureSessionSchema, type BrowserCaptureSession } from "@thriftycrew/contracts";
import { digestHex, stableJson } from "@thriftycrew/domain";
import { browserCaptureCycleWindow } from "./browser-capture-sla";

function uint16(bytes: Uint8Array, offset: number, littleEndian: boolean): number {
  return littleEndian ? bytes[offset]! | bytes[offset + 1]! << 8 : bytes[offset]! << 8 | bytes[offset + 1]!;
}

function uint24le(bytes: Uint8Array, offset: number): number {
  return bytes[offset]! | bytes[offset + 1]! << 8 | bytes[offset + 2]! << 16;
}

function uint32be(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset]! << 24) | (bytes[offset + 1]! << 16) | (bytes[offset + 2]! << 8) | bytes[offset + 3]!) >>> 0;
}

export function screenshotDimensions(bytes: Uint8Array, contentType: string): { width: number; height: number } {
  if (bytes.length < 512) throw new Error("screenshot evidence is implausibly small");
  const mime = contentType.split(";", 1)[0]!.trim().toLowerCase();
  if (mime === "image/png") {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 24 || !signature.every((value, index) => bytes[index] === value) || new TextDecoder().decode(bytes.slice(12, 16)) !== "IHDR") throw new Error("invalid PNG screenshot evidence");
    return { width: uint32be(bytes, 16), height: uint32be(bytes, 20) };
  }
  if (mime === "image/jpeg") {
    if (bytes[0] !== 0xff || bytes[1] !== 0xd8) throw new Error("invalid JPEG screenshot evidence");
    let offset = 2;
    while (offset + 8 < bytes.length) {
      if (bytes[offset] !== 0xff) { offset += 1; continue; }
      const marker = bytes[offset + 1]!;
      if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker)) return { height: uint16(bytes, offset + 5, false), width: uint16(bytes, offset + 7, false) };
      const length = uint16(bytes, offset + 2, false);
      if (length < 2) break;
      offset += 2 + length;
    }
    throw new Error("JPEG screenshot evidence has no dimensions");
  }
  if (mime === "image/webp") {
    if (bytes.length < 30 || new TextDecoder().decode(bytes.slice(0, 4)) !== "RIFF" || new TextDecoder().decode(bytes.slice(8, 12)) !== "WEBP") throw new Error("invalid WebP screenshot evidence");
    const kind = new TextDecoder().decode(bytes.slice(12, 16));
    if (kind === "VP8X") return { width: uint24le(bytes, 24) + 1, height: uint24le(bytes, 27) + 1 };
    if (kind === "VP8L" && bytes[20] === 0x2f) {
      const bits = (bytes[21]! | bytes[22]! << 8 | bytes[23]! << 16 | bytes[24]! << 24) >>> 0;
      return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
    }
    if (kind === "VP8 ") return { width: uint16(bytes, 26, true) & 0x3fff, height: uint16(bytes, 28, true) & 0x3fff };
    throw new Error("unsupported WebP screenshot encoding");
  }
  throw new Error(`unsupported screenshot content type ${mime}`);
}

export function validateScreenshotEvidence(bytes: Uint8Array, contentType: string): { width: number; height: number } {
  const dimensions = screenshotDimensions(bytes, contentType);
  if (dimensions.width < 400 || dimensions.height < 200) throw new Error(`screenshot evidence is too small (${dimensions.width}x${dimensions.height})`);
  return dimensions;
}

interface BrowserBatchEvidenceIdentity {
  sourceId: string;
  coverageMode: string;
  capturedFrom: string;
  capturedTo: string;
  expectedTerms: number | null;
}

interface EvidenceRow {
  object_key: string;
  kind: string;
  sha256: string;
}

export interface BrowserCaptureMetricSummary {
  sessionId: string;
  sourceId: string;
  cycleStart: string;
  coverageMode: "full" | "partial" | "targeted" | "ad_only";
  expectedTerms: number;
  attemptedTerms: number;
  successTerms: number;
  emptyTerms: number;
  rejectedTerms: number;
  blockedTerms: number;
  notAttemptedTerms: number;
  retryCount: number;
  chunkCount: number;
  durationMs: number;
  termDurationP50Ms: number;
  termDurationP95Ms: number;
  projectedRows: number;
}

function percentile(values: readonly number[], percentileValue: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.max(0, Math.ceil(sorted.length * percentileValue) - 1)]!;
}

export function summarizeBrowserCaptureSession(session: BrowserCaptureSession): BrowserCaptureMetricSummary {
  const attempted = session.terms.filter((term) => term.outcome !== "not_attempted");
  const durations = attempted.map((term) => Math.max(0, Date.parse(term.finishedAt) - Date.parse(term.startedAt)));
  return {
    sessionId: session.sessionId,
    sourceId: session.sourceId,
    cycleStart: browserCaptureCycleWindow(new Date(session.finishedAt)).cycleStart,
    coverageMode: session.coverageMode,
    expectedTerms: session.expectedTerms,
    attemptedTerms: attempted.length,
    successTerms: session.terms.filter((term) => term.outcome === "success").length,
    emptyTerms: session.terms.filter((term) => term.outcome === "empty").length,
    rejectedTerms: session.terms.filter((term) => term.outcome === "rejected").length,
    blockedTerms: session.terms.filter((term) => term.outcome === "blocked").length,
    notAttemptedTerms: session.terms.filter((term) => term.outcome === "not_attempted").length,
    retryCount: attempted.reduce((sum, term) => sum + Math.max(0, term.attempts - 1), 0),
    chunkCount: session.chunks.length,
    durationMs: Math.max(0, Date.parse(session.finishedAt) - Date.parse(session.startedAt)),
    termDurationP50Ms: percentile(durations, 0.5),
    termDurationP95Ms: percentile(durations, 0.95),
    projectedRows: session.terms.reduce((sum, term) => sum + term.rowCount, 0),
  };
}

export async function validateBrowserCaptureEvidence(
  bucket: R2Bucket,
  batch: BrowserBatchEvidenceIdentity,
  rows: readonly EvidenceRow[],
): Promise<{ pass: boolean; detail: Record<string, unknown>; metrics: BrowserCaptureMetricSummary | null }> {
  const screenshots = rows.filter((row) => row.kind === "screenshot");
  const rawPayloads = rows.filter((row) => row.kind === "raw_payload");
  const manifests = rows.filter((row) => row.kind === "manifest");
  let session: ReturnType<typeof browserCaptureSessionSchema.parse> | null = null;
  for (const row of manifests) {
    const object = await bucket.get(row.object_key);
    if (!object) continue;
    try {
      session = browserCaptureSessionSchema.parse(JSON.parse(await object.text()));
      break;
    } catch {
      // Other manifest evidence cannot authorize browser-session completeness.
    }
  }
  if (!session) return { pass: false, detail: { reason: "missing-valid-capture-session", screenshots: screenshots.length, rawPayloads: rawPayloads.length, manifests: manifests.length }, metrics: null };
  const { contentHash, ...sessionContent } = session;
  const calculatedContentHash = await digestHex(stableJson(sessionContent));
  const screenshotHashes = new Set(screenshots.map((row) => row.sha256));
  const canaryScreenshotHashes = new Set(session.canaries.flatMap((canary) => canary.screenshotSha256 ? [canary.screenshotSha256] : []));
  const screenshotBound = [...canaryScreenshotHashes].some((hash) => screenshotHashes.has(hash));
  const rawBound = rawPayloads.some((row) => row.sha256 === session!.projectedCaptureSha256);
  const identityPass = session.sourceId === batch.sourceId
    && session.coverageMode === batch.coverageMode
    && session.startedAt === batch.capturedFrom
    && session.finishedAt === batch.capturedTo
    && session.expectedTerms === batch.expectedTerms;
  const pass = calculatedContentHash === contentHash && screenshotBound && rawBound && identityPass;
  const trustedSession = calculatedContentHash === contentHash && identityPass;
  return { pass, detail: { sessionId: session.sessionId, contentHashPass: calculatedContentHash === contentHash, screenshotBound, rawBound, identityPass, screenshots: screenshots.length, rawPayloads: rawPayloads.length, manifests: manifests.length }, metrics: trustedSession ? summarizeBrowserCaptureSession(session) : null };
}
