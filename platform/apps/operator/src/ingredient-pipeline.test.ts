import { describe, expect, it } from "vitest";
import { compactEvidenceChunkForCheck, ingredientQaFailureAction, isIdempotentCaptureResumeConflict, isIdempotentQaResumeConflict,
  settleIndependentLanes, storeCheckFailureDisposition } from "./ingredient-pipeline";

describe("ingredient QA failure routing", () => {
  it.each([
    "independent pass found an eligible exact candidate",
    "independent verifier found an eligible exact candidate in the repeated result envelope",
    "independent verification does not reproduce the frozen winner",
    "independent verifier did not reproduce the frozen winner identity, size, and price",
  ])("returns capture conflicts to a fresh producer generation: %s", (reason) => {
    expect(ingredientQaFailureAction(new Error(reason))).toBe("reject_to_capture");
  });

  it.each([
    "source throttled",
    "independent pass did not reproduce complete no-match coverage",
    "network timeout",
  ])("keeps operational failures on the bounded retry lane: %s", (reason) => {
    expect(ingredientQaFailureAction(reason)).toBe("retry");
  });

  it("only treats a lease-fence conflict as an idempotent QA resume", () => {
    expect(isIdempotentQaResumeConflict("POST returned 409: QA completion rejected by lease fence or lane boundary")).toBe(true);
    expect(isIdempotentQaResumeConflict("POST returned 409: independent verifier found an eligible exact candidate")).toBe(false);
  });

  it("only treats a lease-fence conflict as an idempotent capture resume", () => {
    expect(isIdempotentCaptureResumeConflict("capture completion rejected by lease fence or lane boundary")).toBe(true);
    expect(isIdempotentCaptureResumeConflict("capture coverage does not exactly match the locked query plan")).toBe(false);
  });
});

describe("headless source-limit routing", () => {
  it("quarantines a provably incomplete retailer envelope without scheduling another retry", () => {
    expect(storeCheckFailureDisposition(new Error("[headless_source_limit] recovered 300 of 347")))
      .toEqual({ failureClass: "adapter_quarantined", retryAt: null });
    expect(storeCheckFailureDisposition(new Error("temporary network error"), new Date("2026-08-14T12:00:00.000Z")))
      .toEqual({ failureClass: "transient", retryAt: "2026-08-14T12:01:00.000Z" });
  });
});

describe("headless ingredient evidence compaction", () => {
  it("scopes evidence to one claim and removes redundant source projections", () => {
    const check = { commodity_proposal_json: JSON.stringify({ searchTerms: ["freekeh grain", "freekeh"] }) } as any;
    const row = (term: string, id: string) => ({ term, id, name: id, n: id, size: "12 oz", url: `https://example.test/${id}`,
      _capture: { capturedAt: "2026-08-14T00:00:00Z", pageUrl: "https://example.test/search", location: "Omaha",
        priceMode: "in_store", pageIndex: 0, resultIndex: 0, pageState: { query: term },
        visible: { repeated: "x".repeat(10_000) }, structured: { repeated: "x".repeat(10_000) },
        offer: { productName: id, purchasePriceMinor: 399 }, parser: { status: "exact" } } });
    const chunk = { version: 2, phase: "discovery", store: "hy-vee",
      canary: { evidenceUrl: "https://example.test", observedAt: "2026-08-14T00:00:00Z" },
      terms: [
        { query: "freekeh", outcome: "success", excludedResults: Array.from({ length: 200 }, (_, id) => ({ id })) },
        { query: "shawarma seasoning", outcome: "success" },
      ], rows: [row("freekeh", "keep"), row("shawarma seasoning", "drop")] } as any;
    const compacted = compactEvidenceChunkForCheck(check, chunk);
    expect(compacted.terms).toHaveLength(1);
    expect(compacted.rows).toHaveLength(1);
    expect((compacted.rows![0] as any)._capture.visible).toBeUndefined();
    expect((compacted.rows![0] as any)._capture.structured).toBeUndefined();
    expect(JSON.stringify(compacted).length).toBeLessThan(JSON.stringify(chunk).length / 10);
  });
});

describe("independent ingredient worker pools", () => {
  it("starts producer, QA, and catalog work without a serial barrier", async () => {
    const started: string[] = [];
    const releases = new Map<string, () => void>();
    const lane = (name: string, completed: number) => async () => {
      started.push(name);
      await new Promise<void>((resolve) => releases.set(name, resolve));
      return completed;
    };
    const resultPromise = settleIndependentLanes({ catalog: lane("catalog", 1), capture: lane("capture", 2), qa: lane("qa", 3) });
    await Promise.resolve();
    expect(new Set(started)).toEqual(new Set(["catalog", "capture", "qa"]));
    for (const release of releases.values()) release();
    await expect(resultPromise).resolves.toEqual({
      catalog: { completed: 1, error: null }, capture: { completed: 2, error: null }, qa: { completed: 3, error: null },
    });
  });

  it("isolates one failed role so sibling queues still complete", async () => {
    await expect(settleIndependentLanes({
      catalog: async () => 4,
      capture: async () => { throw new Error("retailer refused one producer"); },
      qa: async () => 5,
    })).resolves.toEqual({
      catalog: { completed: 4, error: null },
      capture: { completed: 0, error: "retailer refused one producer" },
      qa: { completed: 5, error: null },
    });
  });
});
