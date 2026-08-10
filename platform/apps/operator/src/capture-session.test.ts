import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { appendCaptureChunk, captureSessionStatus, finalizeCaptureSession, initializeCaptureSession } from "./capture-session";

const roots: string[] = [];
const screenshotSha256 = "a".repeat(64);

function chunk(query: string, outcome: "success" | "blocked", attempts: number, minute: number) {
  const observedAt = `2026-08-12T15:${String(minute).padStart(2, "0")}:00.000Z`;
  return {
    version: 1,
    store: "walmart",
    canary: {
      observedAt, market: "Omaha", location: "Omaha L St Supercenter", priceMode: "pickup",
      evidenceUrl: "https://www.walmart.com/search?q=milk", marketVerified: true, locationVerified: true, priceModeVerified: true,
      ...(minute === 0 ? { screenshotSha256 } : {}),
    },
    terms: [{ query, outcome, rowCount: outcome === "success" ? 1 : 0, attempts, startedAt: observedAt, finishedAt: `2026-08-12T15:${String(minute + 1).padStart(2, "0")}:00.000Z`, ...(outcome === "blocked" ? { reason: "retailer challenge" } : {}) }],
    rows: outcome === "success" ? [{ q: query, n: `${query} product`, lp: "$1.99", up: "$0.10/oz", id: `${query}-id`, taxonomy_path: "Food/Dairy" }] : [],
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
    expect(await captureSessionStatus(directory)).toMatchObject({ expectedTerms: 2, attemptedTerms: 2, chunks: 3 });
    const projected = path.join(root, "walmart-capture.csv");
    const manifestFile = path.join(root, "capture-session-manifest.json");
    const manifest = await finalizeCaptureSession(directory, projected, manifestFile, "2026-08-12T15:06:00.000Z");
    expect(manifest).toMatchObject({ coverageMode: "full", expectedTerms: 2 });
    expect(manifest.terms).toEqual([
      expect.objectContaining({ query: "milk", ordinal: 0, outcome: "success", attempts: 1, rowCount: 1 }),
      expect.objectContaining({ query: "eggs", ordinal: 1, outcome: "success", attempts: 2, rowCount: 1 }),
    ]);
    expect(manifest.canaries).toHaveLength(3);
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
