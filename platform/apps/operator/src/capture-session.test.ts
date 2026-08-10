import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { appendCaptureChunk, buildCaptureVerificationPlan, captureSessionStatus, finalizeCaptureSession, initializeCaptureSession } from "./capture-session";

const roots: string[] = [];
const screenshotSha256 = "a".repeat(64);

function chunk(query: string, outcome: "success" | "blocked", attempts: number, minute: number) {
  const observedAt = `2026-08-12T15:${String(minute).padStart(2, "0")}:00.000Z`;
  return {
    version: 2,
    phase: "discovery",
    store: "walmart",
    canary: {
      observedAt, market: "Omaha", location: "Omaha L St Supercenter", priceMode: "pickup",
      evidenceUrl: "https://www.walmart.com/search?q=milk", marketVerified: true, locationVerified: true, priceModeVerified: true,
      ...(minute === 0 ? { screenshotSha256 } : {}),
    },
    terms: [{
      query, outcome, rowCount: outcome === "success" ? 1 : 0, attempts, startedAt: observedAt,
      finishedAt: `2026-08-12T15:${String(minute + 1).padStart(2, "0")}:00.000Z`,
      retrieval: outcome === "success"
        ? { targetResultCount: 1, loadedResultCount: 1, availableResultCount: 1, pageCount: 1, hasMoreResults: false, termination: "end-of-results" }
        : { targetResultCount: 1, loadedResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "blocked" },
      ...(outcome === "blocked" ? { reason: "retailer challenge" } : {}),
    }],
    rows: outcome === "success" ? [{
      q: query, n: `${query} product`, lp: "$1.99", up: "$0.10/oz", id: `${query}-id`, size: "12 ct", taxonomy_path: "Food/Dairy",
      _capture: {
        capturedAt: observedAt, pageUrl: `https://www.walmart.com/search?q=${query}`, location: "Omaha L St Supercenter", priceMode: "pickup",
        pageIndex: 0, resultIndex: 0,
        visible: { rawText: "$1.99", priceMinor: 199, productName: `${query} product`, sizeText: "12 ct" },
        structured: { rawText: "1.99", priceMinor: 199, productName: `${query} product`, productKey: `${query}-id`, sizeText: "12 ct" },
        parser: { status: "exact", rule: "next-data-price-lines" },
      },
    }] : [],
  };
}

function verificationChunk(targets: Array<Record<string, unknown>>) {
  const observedAt = "2026-08-12T15:07:00.000Z";
  return {
    version: 2, phase: "verification", store: "walmart",
    canary: {
      observedAt, market: "Omaha", location: "Omaha L St Supercenter", priceMode: "pickup",
      evidenceUrl: "https://www.walmart.com/search?q=milk", marketVerified: true, locationVerified: true, priceModeVerified: true,
    },
    verifications: targets.map((target) => ({
      rowKey: target.rowKey, discoveryHash: target.discoveryHash, observedAt, outcome: "observed",
      productKey: target.productKey, name: target.name, sizeText: target.sizeText, purchasePriceMinor: target.purchasePriceMinor,
      truth: {
        capturedAt: observedAt, pageUrl: target.pageUrl, location: "Omaha L St Supercenter", priceMode: "pickup", pageIndex: 0, resultIndex: 0,
        visible: { rawText: "$1.99", priceMinor: 199, productName: target.name, sizeText: target.sizeText },
        structured: { rawText: "1.99", priceMinor: 199, productName: target.name, productKey: target.productKey, sizeText: target.sizeText },
        parser: { status: "exact", rule: "next-data-price-lines" },
      },
    })),
  };
}

afterEach(async () => Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))));

describe("resumable browser capture sessions", () => {
  it("hashes the worklist, replaces a failed term with its retry, and emits a full real term ledger", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-browser-session-"));
    roots.push(root);
    const worklist = path.join(root, "worklist.txt");
    const directory = path.join(root, "session");
    await writeFile(worklist, "milk\neggs\n", "utf8");
    const initialized = await initializeCaptureSession("walmart", worklist, directory, "2026-08-12T15:00:00.000Z");
    expect(initialized.worklist.map((term) => term.query)).toEqual(["milk", "eggs"]);
    for (const [name, value] of [["milk.json", chunk("milk", "success", 1, 0)], ["eggs-blocked.json", chunk("eggs", "blocked", 1, 2)], ["eggs-retry.json", chunk("eggs", "success", 2, 4)]] as const) {
      const file = path.join(root, name);
      await writeFile(file, JSON.stringify(value));
      await appendCaptureChunk(directory, file);
    }
    expect(await captureSessionStatus(directory)).toMatchObject({ expectedTerms: 2, attemptedTerms: 2, chunks: 3, unresolvedVerifications: 2, accuracyPass: false });
    const planFile = path.join(root, "verification-plan.json");
    await buildCaptureVerificationPlan(directory, planFile);
    const plan = JSON.parse(await readFile(planFile, "utf8")) as { targets: Array<Record<string, unknown>> };
    expect(plan.targets).toHaveLength(2);
    const verificationFile = path.join(root, "verification.json");
    await writeFile(verificationFile, JSON.stringify(verificationChunk(plan.targets)));
    await appendCaptureChunk(directory, verificationFile);
    expect(await captureSessionStatus(directory)).toMatchObject({ matchedVerifications: 2, unresolvedVerifications: 0, accuracyPass: true });
    const projected = path.join(root, "walmart-capture.csv");
    const manifestFile = path.join(root, "capture-session-manifest.json");
    const manifest = await finalizeCaptureSession(directory, projected, manifestFile, "2026-08-12T15:08:00.000Z");
    expect(manifest).toMatchObject({ version: 2, coverageMode: "full", expectedTerms: 2, accuracy: { pass: true, requiredVerificationRows: 2, matchedVerificationRows: 2 } });
    expect(manifest.terms).toEqual([
      expect.objectContaining({ query: "milk", ordinal: 0, outcome: "success", attempts: 1, rowCount: 1 }),
      expect.objectContaining({ query: "eggs", ordinal: 1, outcome: "success", attempts: 2, rowCount: 1 }),
    ]);
    expect(manifest.canaries).toHaveLength(4);
    expect(await readFile(projected, "utf8")).toContain("Food/Dairy");
    expect(JSON.parse(await readFile(manifestFile, "utf8"))).toMatchObject({ contentHash: manifest.contentHash, projectedCaptureSha256: manifest.projectedCaptureSha256 });
  });

  it("rejects a chunk that cannot prove the required location", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-browser-session-"));
    roots.push(root);
    const worklist = path.join(root, "worklist.txt");
    const directory = path.join(root, "session");
    await writeFile(worklist, "milk\n", "utf8");
    await initializeCaptureSession("walmart", worklist, directory, "2026-08-12T15:00:00.000Z");
    const value = chunk("milk", "success", 1, 0);
    value.canary.location = "Lincoln Supercenter";
    const file = path.join(root, "bad.json");
    await writeFile(file, JSON.stringify(value));
    await expect(appendCaptureChunk(directory, file)).rejects.toThrow("required Omaha location");
  });
});
