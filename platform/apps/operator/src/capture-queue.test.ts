import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { buildBrowserCaptureAccuracy, digestHex, stableJson } from "@thriftycrew/domain";
import { browserCaptureCycleStatus, captureQueueStatus, compactPromotedCaptureQueue, drainCaptureQueue, enqueueCapture, PermanentCaptureError, reconcileCaptureQueueRemote, verifyCaptureQueueFilesystem } from "./capture-queue";
import { closeCaptureJournals } from "./capture-journal";

const roots: string[] = [];

function proofPng(): Uint8Array {
  const bytes = new Uint8Array(512);
  bytes.set([137, 80, 78, 71, 13, 10, 26, 10], 0);
  bytes.set([73, 72, 68, 82], 12);
  new DataView(bytes.buffer).setUint32(16, 1280);
  new DataView(bytes.buffer).setUint32(20, 720);
  return bytes;
}

async function fixture(sourceId = "direct-walmart-browser", captureDate = "2026-08-09"): Promise<{ root: string; artifact: string; screenshot: string; raw: string; session: string; evidence: string[] }> {
  const root = await mkdtemp(path.join(os.tmpdir(), "tc-capture-queue-"));
  roots.push(root);
  const artifact = path.join(root, "input.json");
  const screenshot = path.join(root, "proof.png");
  const raw = path.join(root, "projected.csv");
  const sessionFile = path.join(root, "capture-session.json");
  const store = sourceId.includes("aldi") ? "aldi" : sourceId.includes("fareway") ? "fareway" : sourceId.includes("sams") ? "sams" : "walmart";
  const start = `${captureDate}T15:00:00.000Z`;
  const finish = `${captureDate}T15:02:00.000Z`;
  const screenshotBytes = proofPng();
  const rawBytes = new TextEncoder().encode("q|n|lp|up|id\neggs|Large Eggs|$1.99|$1.99/dozen|123\n");
  const screenshotSha256 = await digestHex(screenshotBytes);
  const projectedCaptureSha256 = await digestHex(rawBytes);
  const location = store === "walmart" ? "Omaha L St Supercenter" : store === "sams" ? "Omaha Sam's Club" : store === "aldi" ? "ALDI OLA 42 Omaha" : "17070 Audrey Street Omaha";
  const priceMode = store === "walmart" ? "pickup" : store === "sams" ? "club pickup" : "in-store";
  const pageUrl = store === "walmart" ? "https://www.walmart.com/search?q=eggs" : store === "sams" ? "https://www.samsclub.com/s/eggs" : store === "aldi" ? "https://www.aldi.us/results?q=eggs" : "https://shop.fareway.com/search?q=eggs";
  const dual = store === "walmart" || store === "sams";
  const priceSemantics = store === "sams"
    ? { offerType: "member" as const, condition: "membership" as const, unitPriceMinor: 199, qualifyingQuantity: 1, totalPriceMinor: 199, ambiguity: false as const }
    : { offerType: "everyday" as const, condition: "none" as const, unitPriceMinor: 199, qualifyingQuantity: 1, totalPriceMinor: 199, ambiguity: false as const };
  const discoveryTruth = {
    capturedAt: `${captureDate}T15:01:00.000Z`, pageUrl, location, priceMode, pageIndex: 0, resultIndex: 0,
    pageState: { pageType: "search_results" as const, pageTitle: "eggs search", query: "eggs", resultRegionPresent: true as const, challengeDetected: false as const, currency: "USD" as const, locale: "en-US", locationText: location, fulfillmentText: priceMode },
    visible: { rawText: "$1.99", priceMinor: 199, productName: "Large Eggs", sizeText: "12 ct", priceSemantics },
    ...(dual ? { structured: { rawText: "1.99", priceMinor: 199, productName: "Large Eggs", productKey: "123", sizeText: "12 ct", priceSemantics } } : {}),
    parser: { status: "exact" as const, rule: dual ? "next-data-price-lines" as const : "current-price-label" as const },
  };
  const terms = [{
    termKey: "eggs", query: "eggs", ordinal: 0, outcome: "success" as const, rowCount: 1, attempts: 1, startedAt: start, finishedAt: `${captureDate}T15:01:00.000Z`,
    retrieval: { targetResultCount: 1, loadedResultCount: 1, availableResultCount: 1, pageCount: 1, hasMoreResults: false, termination: "end-of-results" as const },
  }];
  const candidate = { termKey: "eggs", query: "eggs", productKey: "123", name: "Large Eggs", sizeText: "12 ct", taxonomyPath: "Food/Dairy", purchasePriceMinor: 199, truth: discoveryTruth };
  const provisional = await buildBrowserCaptureAccuracy(store, [candidate], [], terms);
  const target = provisional.discoveryRows[0]!;
  const verificationTruth = { ...discoveryTruth, capturedAt: `${captureDate}T15:01:30.000Z` };
  const verifications = [{
    rowKey: target.rowKey, discoveryHash: target.discoveryHash, observedAt: `${captureDate}T15:01:30.000Z`, outcome: "observed" as const,
    productKey: "123", name: "Large Eggs", sizeText: "12 ct", purchasePriceMinor: 199, truth: verificationTruth,
  }];
  const accuracy = await buildBrowserCaptureAccuracy(store, [candidate], verifications, terms);
  const sessionContent = {
    version: 2 as const, sessionId: `browser-${store}-${captureDate}-fixture`, store, sourceId,
    worklistHash: "b".repeat(64), startedAt: start, finishedAt: finish, coverageMode: "full" as const, expectedTerms: 1,
    terms,
    canaries: [
      { ordinal: 0, observedAt: start, market: "Omaha", location, priceMode, evidenceUrl: pageUrl, marketVerified: true as const, locationVerified: true as const, priceModeVerified: true as const, screenshotSha256 },
      { ordinal: 1, observedAt: `${captureDate}T15:01:30.000Z`, market: "Omaha", location, priceMode, evidenceUrl: pageUrl, marketVerified: true as const, locationVerified: true as const, priceModeVerified: true as const },
    ],
    chunks: [
      { id: "chunk-discovery", phase: "discovery" as const, ordinal: 0, termKeys: ["eggs"], rowCount: 1, verificationCount: 0, sha256: "c".repeat(64), createdAt: `${captureDate}T15:01:00.000Z` },
      { id: "chunk-verification", phase: "verification" as const, ordinal: 1, termKeys: [], rowCount: 0, verificationCount: 1, sha256: "d".repeat(64), createdAt: `${captureDate}T15:01:30.000Z` },
    ],
    accuracy,
    dailyShards: [{ date: captureDate, ordinal: 0, contentHash: "e".repeat(64), termCount: 1, rowCount: 1, chunkCount: 2, firstObservedAt: start, lastObservedAt: `${captureDate}T15:01:30.000Z` }],
    projectedCaptureSha256,
  };
  const session = { ...sessionContent, contentHash: await digestHex(stableJson(sessionContent)) };
  await writeFile(sessionFile, JSON.stringify(session));
  await writeFile(raw, rawBytes);
  await writeFile(screenshot, screenshotBytes);
  await writeFile(artifact, JSON.stringify({
    version: 1,
    sourceId,
    coverageMode: "full",
    capturedFrom: start,
    capturedTo: finish,
    expectedTerms: 1,
    marketVerified: true,
    locationVerified: true,
    priceModeVerified: true,
    priceMode,
    idempotencyKey: `browser-${store}-${captureDate}-fixture`,
    terms: [{ termKey: "eggs", ordinal: 0, outcome: "success", rowCount: 1 }],
    observations: [{
      externalProductKey: "123", name: "Large Eggs", sizeText: "12 ct", productUrl: "https://example.com/eggs",
      package: {}, termKey: "eggs", kind: "everyday", currency: "USD", purchasePriceMinor: 199,
      purchaseQuantity: 1, packageCount: 1, capturedBasisUnit: "each", capturedBasisQtyMicros: 12_000_000,
      normalizedBasisUnit: "dozen", normalizedBasisQtyMicros: 1_000_000, perUnitMicros: 1_990_000,
      loyaltyRequired: false, membershipRequired: false, rawPriceText: "$1.99", rawSizeText: "12 ct",
      capturedAt: `${captureDate}T15:01:00.000Z`,
    }],
    audit: { captureSession: session, attestation: { verifiedAt: start, captureSessionHash: session.contentHash, screenshotSha256: [screenshotSha256] } },
  }));
  return { root: path.join(root, "queue"), artifact, screenshot, raw, session: sessionFile, evidence: [screenshot, raw, sessionFile] };
}

afterEach(async () => {
  closeCaptureJournals();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("PC browser capture queue", () => {
  it("copies and hashes a browser job idempotently with immutable proof evidence", async () => {
    const input = await fixture();
    const first = await enqueueCapture(input.root, input.artifact, input.evidence, new Date("2026-08-09T15:02:00.000Z"));
    const second = await enqueueCapture(input.root, input.artifact, input.evidence, new Date("2026-08-09T15:03:00.000Z"));
    expect(first.idempotent).toBe(false);
    expect(second).toMatchObject({ id: first.id, idempotent: true });
    expect(first.manifest.evidence.map((item) => item.kind).sort()).toEqual(["manifest", "raw_payload", "screenshot"]);
    expect(await verifyCaptureQueueFilesystem(input.root)).toMatchObject({ ok: true, jobs: 1 });
  });

  it("reads a pre-cutover queued artifact whose verified price mode only exists in its immutable attestation", async () => {
    const input = await fixture("direct-walmart-browser", "2026-08-09");
    const queued = await enqueueCapture(input.root, input.artifact, input.evidence, new Date("2026-08-09T15:02:00.000Z"));
    const artifactPath = path.join(queued.directory, "artifact.json");
    const artifact = JSON.parse(await readFile(artifactPath, "utf8"));
    delete artifact.priceMode;
    artifact.audit = { attestation: { priceMode: "pickup", priceModeVerified: true } };
    const artifactBytes = new TextEncoder().encode(JSON.stringify(artifact));
    await writeFile(artifactPath, artifactBytes);
    const manifestPath = path.join(queued.directory, "manifest.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    manifest.artifactSha256 = await digestHex(artifactBytes);
    manifest.status = "completed";
    await writeFile(manifestPath, JSON.stringify(manifest));

    expect(await verifyCaptureQueueFilesystem(input.root)).toMatchObject({ ok: true, jobs: 1 });
    expect(await browserCaptureCycleStatus(input.root, new Date("2026-08-10T15:00:00.000Z"))).toMatchObject({ completed: ["direct-walmart-browser"] });
  });

  it("does not backfill an absent price mode after the accuracy cutover", async () => {
    const input = await fixture("direct-walmart-browser", "2026-08-12");
    const queued = await enqueueCapture(input.root, input.artifact, input.evidence, new Date("2026-08-12T15:02:00.000Z"));
    const artifactPath = path.join(queued.directory, "artifact.json");
    const artifact = JSON.parse(await readFile(artifactPath, "utf8"));
    delete artifact.priceMode;
    artifact.audit.attestation.priceMode = "pickup";
    artifact.audit.attestation.priceModeVerified = true;
    const artifactBytes = new TextEncoder().encode(JSON.stringify(artifact));
    await writeFile(artifactPath, artifactBytes);
    const manifestPath = path.join(queued.directory, "manifest.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    manifest.artifactSha256 = await digestHex(artifactBytes);
    await writeFile(manifestPath, JSON.stringify(manifest));

    await expect(verifyCaptureQueueFilesystem(input.root)).rejects.toThrow("priceMode");
  });

  it("rejects headless artifacts, incomplete evidence, and fake screenshots", async () => {
    const headless = await fixture("direct-walmart-headless");
    await expect(enqueueCapture(headless.root, headless.artifact, headless.evidence)).rejects.toThrow("only accepts direct browser");
    const browser = await fixture();
    await expect(enqueueCapture(browser.root, browser.artifact, [browser.raw, browser.session])).rejects.toThrow("requires screenshot");
    await writeFile(browser.screenshot, new Uint8Array(512));
    await expect(enqueueCapture(browser.root, browser.artifact, browser.evidence)).rejects.toThrow("invalid PNG");
  });

  it("retains a failed upload, backs off, then records and reconciles the server receipt", async () => {
    const input = await fixture("direct-walmart-browser", "2026-08-12");
    const queued = await enqueueCapture(input.root, input.artifact, input.evidence, new Date("2026-08-12T15:00:00.000Z"));
    const failed = await drainCaptureQueue(input.root, async () => { throw new Error("network interrupted"); }, { now: new Date("2026-08-12T15:01:00.000Z") });
    expect(failed).toMatchObject({ ok: false, processed: 1, failed: 1 });
    const held = await drainCaptureQueue(input.root, async () => ({ shouldNotRun: true }), { now: new Date("2026-08-12T15:01:10.000Z") });
    expect(held).toMatchObject({ processed: 0, skipped: 1 });
    const recovered = await drainCaptureQueue(input.root, async (job) => ({ ok: true, batchId: `batch-${job.manifest.id}`, status: "validated" }), { now: new Date("2026-08-12T15:02:00.000Z") });
    expect(recovered).toMatchObject({ ok: true, completed: 1 });
    expect(await browserCaptureCycleStatus(input.root, new Date("2026-08-12T16:00:00.000Z"))).toMatchObject({ status: "due", inflight: ["direct-walmart-browser"] });
    expect(await reconcileCaptureQueueRemote(input.root, async () => ({ status: "promoted", matching: { status: "passed" } }))).toMatchObject({ checked: 1, ready: 1, errors: 0 });
    expect(await browserCaptureCycleStatus(input.root, new Date("2026-08-12T16:01:00.000Z"))).toMatchObject({ status: "due", completed: ["direct-walmart-browser"] });
    expect(await compactPromotedCaptureQueue(input.root, new Date("2026-08-12T16:02:00.000Z"))).toMatchObject({ checked: 1, compacted: 1 });
    expect(await verifyCaptureQueueFilesystem(input.root)).toMatchObject({ ok: true, jobs: 1 });
    expect(await browserCaptureCycleStatus(input.root, new Date("2026-08-12T16:03:00.000Z"))).toMatchObject({ completed: ["direct-walmart-browser"] });
    const receipt = JSON.parse(await readFile(path.join(queued.directory, "receipt.json"), "utf8"));
    expect(receipt.remote).toMatchObject({ status: "promoted", matching: { status: "passed" } });
  });

  it("makes an old or repeatedly failing queue job fail the watchdog", async () => {
    const input = await fixture();
    await enqueueCapture(input.root, input.artifact, input.evidence, new Date("2026-08-09T10:00:00.000Z"));
    const status = await captureQueueStatus(input.root, { now: new Date("2026-08-09T15:01:00.000Z"), maxPendingMinutes: 180 });
    expect(status.ok).toBe(false);
    expect(status.unhealthyJobs[0]).toMatchObject({ sourceId: "direct-walmart-browser", ageMinutes: 301 });
  });

  it("does not retry a permanent server rejection", async () => {
    const input = await fixture();
    await enqueueCapture(input.root, input.artifact, input.evidence, new Date("2026-08-09T15:00:00.000Z"));
    const rejected = await drainCaptureQueue(input.root, async () => { throw new PermanentCaptureError("stale capture window"); }, { now: new Date("2026-08-09T15:01:00.000Z") });
    expect(rejected.results[0]).toMatchObject({ status: "rejected", attempts: 1 });
    expect((await drainCaptureQueue(input.root, async () => ({ shouldNotRun: true }), { now: new Date("2026-08-10T15:01:00.000Z") })).processed).toBe(0);
    expect(await captureQueueStatus(input.root, { now: new Date("2026-08-09T15:02:00.000Z") })).toMatchObject({ ok: false, rejected: 1 });
  });

  it("alerts only after the browser retry window or when a prior week was missed", async () => {
    const inputs = await Promise.all(["aldi", "fareway", "sams", "walmart"].map((store) => fixture(`direct-${store}-browser`, "2026-08-12")));
    const root = inputs[0]!.root;
    for (const input of inputs) await enqueueCapture(root, input.artifact, input.evidence, new Date("2026-08-12T15:02:00.000Z"));
    await drainCaptureQueue(root, async (job) => ({ ok: true, batchId: `batch-${job.manifest.id}`, status: "validated" }), { now: new Date("2026-08-12T15:03:00.000Z") });
    await reconcileCaptureQueueRemote(root, async () => ({ status: "promoted", matching: { status: "passed" } }));
    expect(await browserCaptureCycleStatus(root, new Date("2026-08-13T15:00:00.000Z"))).toMatchObject({ status: "fresh", alertDue: false });
    expect(await browserCaptureCycleStatus(root, new Date("2026-08-19T15:00:00.000Z"))).toMatchObject({ status: "due", alertDue: false });
    expect(await browserCaptureCycleStatus(root, new Date("2026-08-22T18:00:00.000Z"))).toMatchObject({ status: "due", alertDue: true });
    expect(await browserCaptureCycleStatus(root, new Date("2026-08-26T05:00:00.000Z"))).toMatchObject({ status: "due", alertDue: true });
  });
});
