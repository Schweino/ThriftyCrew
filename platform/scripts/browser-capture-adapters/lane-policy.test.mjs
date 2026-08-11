import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { browserLanePolicy, recordBrowserLaneResult, withBrowserStoreLane } from "./lane-policy.mjs";

const roots = [];
afterEach(async () => Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))));

describe("browser store lane policy", () => {
  it("backs off and opens a store-local circuit without affecting another store", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-browser-lane-"));
    roots.push(root);
    const environment = { LOCALAPPDATA: root };
    const first = await browserLanePolicy("aldi", new Date("2026-08-12T15:00:00Z"), environment);
    expect(first).toMatchObject({ maxTerms: 3, dynamicDelayMs: 5000 });
    await recordBrowserLaneResult("aldi", "blocked", 1200, new Date("2026-08-12T15:01:00Z"), environment);
    await expect(browserLanePolicy("aldi", new Date("2026-08-12T15:02:00Z"), environment)).rejects.toThrow("circuit is open");
    await expect(browserLanePolicy("walmart", new Date("2026-08-12T15:02:00Z"), environment)).resolves.toMatchObject({ maxTerms: 5 });
  });

  it("enforces one active operation per store", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-browser-lane-"));
    roots.push(root);
    const environment = { LOCALAPPDATA: root };
    let release;
    const held = withBrowserStoreLane("sams", () => new Promise((resolve) => { release = resolve; }), environment);
    await new Promise((resolve) => setTimeout(resolve, 10));
    await expect(withBrowserStoreLane("sams", async () => null, environment)).rejects.toThrow("active capture");
    release(null);
    await held;
  });
});
