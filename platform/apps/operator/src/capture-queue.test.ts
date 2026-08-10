import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { captureQueueStatus, drainCaptureQueue, enqueueCapture, PermanentCaptureError, verifyCaptureQueueFilesystem } from "./capture-queue";

const roots: string[] = [];

async function fixture(sourceId = "direct-walmart-browser"): Promise<{ root: string; artifact: string; screenshot: string }> {
  const root = await mkdtemp(path.join(os.tmpdir(), "tc-capture-queue-"));
  roots.push(root);
  const artifact = path.join(root, "input.json");
  const screenshot = path.join(root, "proof.png");
  await writeFile(artifact, JSON.stringify({
    version: 1,
    sourceId,
    coverageMode: "targeted",
    capturedFrom: "2026-08-09T15:00:00.000Z",
    capturedTo: "2026-08-09T15:01:00.000Z",
    marketVerified: true,
    locationVerified: true,
    priceModeVerified: true,
    idempotencyKey: "browser-walmart-2026-08-09-fixture",
    terms: [{ termKey: "eggs", ordinal: 0, outcome: "success", rowCount: 1 }],
    observations: [{
      externalProductKey: "123", name: "Large Eggs", sizeText: "12 ct", productUrl: "https://example.com/eggs",
      package: {}, termKey: "eggs", kind: "everyday", currency: "USD", purchasePriceMinor: 199,
      purchaseQuantity: 1, packageCount: 1, capturedBasisUnit: "each", capturedBasisQtyMicros: 12_000_000,
      normalizedBasisUnit: "dozen", normalizedBasisQtyMicros: 1_000_000, perUnitMicros: 1_990_000,
      loyaltyRequired: false, membershipRequired: false, rawPriceText: "$1.99", rawSizeText: "12 ct",
      capturedAt: "2026-08-09T15:00:00.000Z",
    }],
    audit: {},
  }));
  await writeFile(screenshot, new Uint8Array([137, 80, 78, 71, 1, 2, 3]));
  return { root: path.join(root, "queue"), artifact, screenshot };
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("PC browser capture queue", () => {
  it("copies and hashes a browser job idempotently", async () => {
    const input = await fixture();
    const first = await enqueueCapture(input.root, input.artifact, [input.screenshot], new Date("2026-08-09T15:02:00.000Z"));
    const second = await enqueueCapture(input.root, input.artifact, [input.screenshot], new Date("2026-08-09T15:03:00.000Z"));
    expect(first.idempotent).toBe(false);
    expect(second).toMatchObject({ id: first.id, idempotent: true });
    expect(await verifyCaptureQueueFilesystem(input.root)).toMatchObject({ ok: true, jobs: 1 });
  });

  it("rejects headless artifacts and browser jobs without screenshots", async () => {
    const headless = await fixture("direct-walmart-headless");
    await expect(enqueueCapture(headless.root, headless.artifact, [headless.screenshot])).rejects.toThrow("only accepts direct browser");
    const browser = await fixture();
    await expect(enqueueCapture(browser.root, browser.artifact, [])).rejects.toThrow("requires at least one screenshot");
  });

  it("retains a failed upload, backs off, then records the server receipt", async () => {
    const input = await fixture();
    const queued = await enqueueCapture(input.root, input.artifact, [input.screenshot], new Date("2026-08-09T15:00:00.000Z"));
    const failed = await drainCaptureQueue(input.root, async () => { throw new Error("network interrupted"); }, { now: new Date("2026-08-09T15:01:00.000Z") });
    expect(failed).toMatchObject({ ok: false, processed: 1, failed: 1 });
    const held = await drainCaptureQueue(input.root, async () => ({ shouldNotRun: true }), { now: new Date("2026-08-09T15:01:10.000Z") });
    expect(held).toMatchObject({ processed: 0, skipped: 1 });
    const recovered = await drainCaptureQueue(input.root, async (job) => ({ ok: true, batchId: `batch-${job.manifest.id}` }), { now: new Date("2026-08-09T15:02:00.000Z") });
    expect(recovered).toMatchObject({ ok: true, completed: 1 });
    const receipt = JSON.parse(await readFile(path.join(queued.directory, "receipt.json"), "utf8"));
    expect(receipt.batchId).toBe(`batch-${queued.id}`);
    expect(await captureQueueStatus(input.root, { now: new Date("2026-08-09T16:00:00.000Z") })).toMatchObject({ ok: true, completed: 1, pending: 0, retrying: 0 });
  });

  it("makes an old or repeatedly failing queue job fail the watchdog", async () => {
    const input = await fixture();
    await enqueueCapture(input.root, input.artifact, [input.screenshot], new Date("2026-08-09T10:00:00.000Z"));
    const status = await captureQueueStatus(input.root, { now: new Date("2026-08-09T15:01:00.000Z"), maxPendingMinutes: 180 });
    expect(status.ok).toBe(false);
    expect(status.unhealthyJobs).toHaveLength(1);
    expect(status.unhealthyJobs[0]).toMatchObject({ sourceId: "direct-walmart-browser", ageMinutes: 301 });
  });

  it("does not retry a permanent server rejection", async () => {
    const input = await fixture();
    await enqueueCapture(input.root, input.artifact, [input.screenshot], new Date("2026-08-09T15:00:00.000Z"));
    const rejected = await drainCaptureQueue(input.root, async () => { throw new PermanentCaptureError("stale capture window"); }, { now: new Date("2026-08-09T15:01:00.000Z") });
    expect(rejected.results[0]).toMatchObject({ status: "rejected", attempts: 1 });
    const second = await drainCaptureQueue(input.root, async () => ({ shouldNotRun: true }), { now: new Date("2026-08-10T15:01:00.000Z") });
    expect(second).toMatchObject({ processed: 0, skipped: 1 });
    expect(await captureQueueStatus(input.root, { now: new Date("2026-08-09T15:02:00.000Z") })).toMatchObject({ ok: false, rejected: 1 });
  });
});
