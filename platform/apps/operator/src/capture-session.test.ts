import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { appendCaptureChunk, buildCaptureSessionWorklist, buildCaptureVerificationPlan, captureSessionStatus, finalizeCaptureSession, initializeCaptureSession, rollingDiscoveryTarget } from "./capture-session";

const roots: string[] = [];
const screenshotSha256 = "a".repeat(64);
const priceSemantics = { offerType: "everyday" as const, condition: "none" as const, unitPriceMinor: 199, qualifyingQuantity: 1, totalPriceMinor: 199, ambiguity: false as const };

describe("rolling browser discovery", () => {
  it("spreads the durable full worklist across four cumulative daily targets", () => {
    expect(rollingDiscoveryTarget(525, new Date("2026-08-12T15:00:00Z"))).toMatchObject({ day: "Wed", shard: 1, cumulativeTarget: 132 });
    expect(rollingDiscoveryTarget(525, new Date("2026-08-15T15:00:00Z"))).toMatchObject({ day: "Sat", shard: 4, cumulativeTarget: 525, remainingAfterTarget: 0 });
  });
});

function pageState(query: string) {
  return { pageType: "search_results" as const, pageTitle: `${query} - Walmart.com`, query, resultRegionPresent: true as const, challengeDetected: false as const, currency: "USD" as const, locale: "en-US", locationText: "Omaha L St Supercenter", fulfillmentText: "pickup" };
}

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
        pageIndex: 0, resultIndex: 0, pageState: pageState(query),
        visible: { rawText: "$1.99", priceMinor: 199, productName: `${query} product`, sizeText: "12 ct", priceSemantics },
        structured: { rawText: "1.99", priceMinor: 199, productName: `${query} product`, productKey: `${query}-id`, sizeText: "12 ct", priceSemantics },
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
        capturedAt: observedAt, pageUrl: target.pageUrl, location: "Omaha L St Supercenter", priceMode: "pickup", pageIndex: 0, resultIndex: 0, pageState: pageState(String(target.query ?? "milk")),
        visible: { rawText: "$1.99", priceMinor: 199, productName: target.name, sizeText: target.sizeText, priceSemantics },
        structured: { rawText: "1.99", priceMinor: 199, productName: target.name, productKey: target.productKey, sizeText: target.sizeText, priceSemantics },
        parser: { status: "exact", rule: "next-data-price-lines" },
      },
    })),
  };
}

function storefrontChunk(store: "aldi" | "fareway", query: string, minute: number) {
  const observedAt = `2026-08-12T15:${String(minute).padStart(2, "0")}:00.000Z`;
  const aldi = store === "aldi";
  const location = aldi ? "ALDI - OLA 42 - Omaha" : "Omaha 17070 Audrey Street";
  const productUrl = aldi
    ? "https://www.aldi.us/store/aldi/products/35001-garlic-3-ct"
    : "https://shop.fareway.com/store/fareway-meat-grocery/products/3253298-garlic-lb";
  const name = "Fresh Garlic 3 ct";
  const pageUrl = aldi ? `https://www.aldi.us/store/aldi/s?k=${query}` : `https://shop.fareway.com/store/fareway-meat-grocery/s?k=${query}`;
  const truth = {
    capturedAt: observedAt, pageUrl, location, priceMode: "In-Store",
    pageIndex: 0, resultIndex: 0,
    pageState: {
      pageType: "search_results" as const, pageTitle: `${query} search`, query, resultRegionPresent: true as const,
      challengeDetected: false as const, currency: "USD" as const, locale: "en-US", locationText: location,
      fulfillmentText: "In-Store",
    },
    visible: { rawText: "Current price: $1.99", priceMinor: 199, productName: name, productKey: productUrl, sizeText: "3 ct", priceSemantics },
    parser: { status: "exact" as const, rule: "current-price-label" },
  };
  return {
    version: 2, phase: "discovery", store,
    canary: {
      observedAt, market: "Omaha", location, priceMode: "In-Store", evidenceUrl: pageUrl, screenshotSha256,
      marketVerified: true, locationVerified: true, priceModeVerified: true,
    },
    terms: [{
      query, outcome: "success", rowCount: 1, attempts: 1, startedAt: observedAt,
      finishedAt: `2026-08-12T15:${String(minute + 1).padStart(2, "0")}:00.000Z`,
      retrieval: { targetResultCount: 1, loadedResultCount: 1, availableResultCount: 1, pageCount: 1, hasMoreResults: false, termination: "end-of-results" },
    }],
    rows: [aldi
      ? { id: "35001", term: query, name, prices: "$1.99", unit: "", size: "3 ct", href: productUrl, taxonomy_path: "Produce", _capture: truth }
      : { id: "3253298", term: query, name, price: "$1.99", per: "", orig: "", unit: "", size: "3 ct", url: productUrl, taxonomy_path: "Produce", _capture: truth }],
  };
}

afterEach(async () => Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))));

describe("resumable browser capture sessions", () => {
  it("bounds status previews while retaining complete term counts", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-browser-session-"));
    roots.push(root);
    const worklist = path.join(root, "worklist.txt");
    const directory = path.join(root, "session");
    await writeFile(worklist, Array.from({ length: 25 }, (_, index) => `term ${index}`).join("\n"), "utf8");
    await initializeCaptureSession("walmart", worklist, directory, "2026-08-12T15:00:00.000Z");
    const status = await captureSessionStatus(directory) as { remainingTermCount: number; remainingTerms: unknown[]; remainingTermsTruncated: boolean };
    expect(status).toMatchObject({ remainingTermCount: 25, remainingTermsTruncated: true });
    expect(status.remainingTerms).toHaveLength(20);
  });

  it("builds a rescue-first query-only worklist from the opposite generated TSV layouts", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-browser-session-"));
    roots.push(root);
    const pullOrder = path.join(root, "pull-order.txt");
    const rescue = path.join(root, "rescue.txt");
    const output = path.join(root, "worklist.json");
    await writeFile(pullOrder, "milk-gallon\tmilk gallon\nlarge-eggs\tlarge eggs\n", "utf8");
    await writeFile(rescue, "# columns: term<TAB>commodityId<TAB>section<TAB>detail\nlarge eggs\tlarge-eggs\tEXPIRING\t2d left\nrye bread\trye-bread\tDROPPED\tmissing\n", "utf8");
    await expect(buildCaptureSessionWorklist(pullOrder, rescue, output)).resolves.toMatchObject({
      pullOrderTerms: 2, rescueTerms: 2, rescueTermsInPullOrder: 1, rescueOnlyTerms: 1, totalTerms: 3,
    });
    expect(JSON.parse(await readFile(output, "utf8"))).toMatchObject({ version: 2, terms: ["large eggs", "rye bread", "milk gallon"], aliases: [], planner: { historyQueries: 0, shadowCoverageTerms: 2 } });
  });

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
    // A total loss of local chunk mirrors is recoverable from the encrypted
    // journal payload bodies; status recreates the evidence files by hash.
    await rm(path.join(directory, "chunks"), { recursive: true, force: true });
    expect(await captureSessionStatus(directory)).toMatchObject({ expectedTerms: 2, attemptedTerms: 2, chunks: 3, unresolvedVerifications: 2, accuracyPass: false });
    const planFile = path.join(root, "verification-plan.json");
    await buildCaptureVerificationPlan(directory, planFile);
    const plan = JSON.parse(await readFile(planFile, "utf8")) as { targets: Array<Record<string, unknown>> };
    expect(plan.targets).toHaveLength(2);
    expect(plan.targets).toEqual(expect.arrayContaining([
      expect.objectContaining({ query: "milk", discoveryCapturedAt: "2026-08-12T15:00:00.000Z" }),
      expect.objectContaining({ query: "eggs", discoveryCapturedAt: "2026-08-12T15:04:00.000Z" }),
    ]));
    const verificationFile = path.join(root, "verification.json");
    await writeFile(verificationFile, JSON.stringify(verificationChunk(plan.targets)));
    await appendCaptureChunk(directory, verificationFile);
    expect(await captureSessionStatus(directory)).toMatchObject({ matchedVerifications: 2, unresolvedVerifications: 0, retrievalCompleteTerms: 2, sourceTruthFailureCount: 0, accuracyPass: true });
    const projected = path.join(root, "walmart-capture.csv");
    const manifestFile = path.join(root, "capture-session-manifest.json");
    const manifest = await finalizeCaptureSession(directory, projected, manifestFile, "2026-08-12T15:08:00.000Z");
    expect(manifest).toMatchObject({
      version: 2, coverageMode: "full", expectedTerms: 2,
      accuracy: { pass: true, requiredVerificationRows: 2, matchedVerificationRows: 2 },
      productEvidence: { version: 1, uniqueProducts: 2, duplicateProductReferences: 0, productReadsRequired: 2, rowVerificationsSatisfied: 2 },
    });
    expect(manifest.terms).toEqual([
      expect.objectContaining({ query: "milk", ordinal: 0, outcome: "success", attempts: 1, rowCount: 1 }),
      expect.objectContaining({ query: "eggs", ordinal: 1, outcome: "success", attempts: 2, rowCount: 1 }),
    ]);
    expect(manifest.canaries).toHaveLength(4);
    expect(await readFile(projected, "utf8")).toContain("Food/Dairy");
    expect(JSON.parse(await readFile(manifestFile, "utf8"))).toMatchObject({ contentHash: manifest.contentHash, projectedCaptureSha256: manifest.projectedCaptureSha256 });
  });

  it.each(["aldi", "fareway"] as const)("projects %s rows with the commodity id expected by the legacy builder", async (store) => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-browser-session-"));
    roots.push(root);
    const worklist = path.join(root, "worklist.tsv");
    const directory = path.join(root, "session");
    await writeFile(worklist, "fresh garlic\n", "utf8");
    await initializeCaptureSession(store, worklist, directory, "2026-08-12T15:00:00.000Z");
    const file = path.join(root, `${store}.json`);
    await writeFile(file, JSON.stringify(storefrontChunk(store, "fresh garlic", 0)));
    await appendCaptureChunk(directory, file);
    const projected = path.join(root, store === "fareway" ? "capture.jsonl" : "capture.csv");
    await finalizeCaptureSession(directory, projected, path.join(root, "manifest.json"), "2026-08-12T15:02:00.000Z");
    const output = await readFile(projected, "utf8");
    if (store === "fareway") {
      expect(JSON.parse(output.trim())).toMatchObject({ id: "fresh-garlic", term: "fresh garlic", candidates: [{ name: "Fresh Garlic 3 ct" }] });
    } else {
      expect(output).toContain("id|term|name|prices");
      expect(output).toContain("fresh-garlic|fresh garlic|Fresh Garlic 3 ct|$1.99");
    }
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
