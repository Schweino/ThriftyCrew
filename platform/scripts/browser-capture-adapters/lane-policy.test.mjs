import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { browserLanePolicy, browserLaneStartDelayMs, jitteredBrowserDelayMs, recordBrowserLaneResult, withBrowserStoreLane } from "./lane-policy.mjs";
import { closeBrowserCaptureJournals } from "./capture-journal.mjs";

const roots = [];
afterEach(async () => {
  closeBrowserCaptureJournals();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("browser store lane policy", () => {
  it("backs off and opens a store-local circuit without affecting another store", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-browser-lane-"));
    roots.push(root);
    const environment = { LOCALAPPDATA: root, TC_CAPTURE_CONTROLLER_ORIGIN: "disabled" };
    const first = await browserLanePolicy("aldi", new Date("2026-08-12T15:00:00Z"), environment);
    expect(first).toMatchObject({ maxTerms: 3, dynamicDelayMs: 5000 });
    await recordBrowserLaneResult("aldi", "blocked", 1200, new Date("2026-08-12T15:01:00Z"), environment);
    await expect(browserLanePolicy("aldi", new Date("2026-08-12T15:02:00Z"), environment)).rejects.toThrow("circuit is open");
    await expect(browserLanePolicy("walmart", new Date("2026-08-12T15:02:00Z"), environment)).resolves.toMatchObject({ maxTerms: 5 });
  });

  it("uses latency EWMA and success streaks to recover lane depth gradually", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-browser-lane-"));
    roots.push(root);
    const environment = { LOCALAPPDATA: root, TC_CAPTURE_CONTROLLER_ORIGIN: "disabled" };
    const failed = await recordBrowserLaneResult("walmart", "rejected", 12_000, new Date("2026-08-12T15:00:00Z"), environment);
    expect(failed).toMatchObject({ dynamicMaxTerms: 2, successStreak: 0 });
    await recordBrowserLaneResult("walmart", "success", 1000, new Date("2026-08-12T15:01:00Z"), environment);
    await recordBrowserLaneResult("walmart", "success", 1000, new Date("2026-08-12T15:02:00Z"), environment);
    const recovered = await recordBrowserLaneResult("walmart", "success", 1000, new Date("2026-08-12T15:03:00Z"), environment);
    expect(recovered.dynamicMaxTerms).toBe(3);
    expect(recovered.ewmaLatencyMs).toBeGreaterThan(0);
  });

  it("enforces one active operation per store", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-browser-lane-"));
    roots.push(root);
    const environment = { LOCALAPPDATA: root, TC_CAPTURE_CONTROLLER_ORIGIN: "disabled" };
    let release;
    const held = withBrowserStoreLane("sams", () => new Promise((resolve) => { release = resolve; }), environment);
    await new Promise((resolve) => setTimeout(resolve, 10));
    await expect(withBrowserStoreLane("sams", async () => null, environment)).rejects.toThrow("active capture");
    release(null);
    await held;
  });

  it("permits all four retailer adapters to hold isolated lanes concurrently", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-browser-four-lanes-"));
    roots.push(root);
    const environment = { LOCALAPPDATA: root, TC_CAPTURE_CONTROLLER_ORIGIN: "disabled" };
    const started = [];
    const releases = new Map();
    const held = ["aldi", "fareway", "sams", "walmart"].map((store) => withBrowserStoreLane(store, () => new Promise((resolve) => {
      started.push(store);
      releases.set(store, resolve);
    }), environment));
    await vi.waitFor(() => expect(started).toHaveLength(4));
    for (const store of started) releases.get(store)(store);
    await expect(Promise.all(held)).resolves.toEqual(["aldi", "fareway", "sams", "walmart"]);
  });

  it("paces one-term chunks from the prior completion instead of letting chunk boundaries bypass Aldi's minimum", () => {
    const policy = { dynamicDelayMs: 5_000, state: { lastCompletedAt: "2026-08-12T15:00:00.000Z" } };
    expect(browserLaneStartDelayMs(policy, Date.parse("2026-08-12T15:00:04.000Z"), () => 0)).toBe(1_500);
  });

  it("does not delay a chunk that already waited beyond the jittered Aldi minimum", () => {
    const policy = { dynamicDelayMs: 5_000, state: { lastCompletedAt: "2026-08-12T15:00:00.000Z" } };
    expect(browserLaneStartDelayMs(policy, Date.parse("2026-08-12T15:00:07.000Z"), () => 1)).toBe(0);
    expect(jitteredBrowserDelayMs(5_000, () => 1)).toBe(6_250);
  });
});
