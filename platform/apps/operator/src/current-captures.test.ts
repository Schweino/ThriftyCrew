import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { findLatestRegularCapture, omahaDateKey, parseServerCaptureStore, readFreshRegularCapture } from "./current-captures";

const roots: string[] = [];

afterEach(async () => Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))));

describe("scheduled server captures", () => {
  it("selects only canonical dated files and ignores partial diagnostics", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-current-capture-"));
    roots.push(root);
    await writeFile(path.join(root, "family-fare-regular-2026-08-08.json"), "{}");
    await writeFile(path.join(root, "family-fare-regular-2026-08-09.PARTIAL.json"), "{}");
    await writeFile(path.join(root, "family-fare-regular-2026-08-09.json"), "{}");
    expect(await findLatestRegularCapture(root, "family-fare")).toBe(path.join(root, "family-fare-regular-2026-08-09.json"));
  });

  it("rejects a stale capture instead of laundering file checkout time", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-current-capture-"));
    roots.push(root);
    const file = path.join(root, "hyvee-regular-2026-08-01.json");
    await writeFile(file, JSON.stringify({ deals: [{ item: "Eggs", size: "dozen", current_price: 1.99, as_of: "2026-08-01" }] }));
    await expect(readFreshRegularCapture(file, { now: new Date("2026-08-09T18:00:00.000Z") })).rejects.toThrow("is stale");
  });

  it("accepts fresh rows and normalizes store aliases", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-current-capture-"));
    roots.push(root);
    const file = path.join(root, "hyvee-regular-2026-08-09.json");
    await writeFile(file, JSON.stringify({ deals: [{ item: "Eggs", size: "dozen", current_price: 1.99, as_of: "2026-08-09" }] }));
    expect(await readFreshRegularCapture(file, { now: new Date("2026-08-09T18:00:00.000Z") })).toMatchObject({ newestCaptureDate: "2026-08-09", rows: 1 });
    expect(parseServerCaptureStore("hyvee")).toBe("hy-vee");
    expect(omahaDateKey(new Date("2026-08-10T02:00:00.000Z"))).toBe("2026-08-09");
  });

  it("requires today's capture for the production schedule", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-current-capture-"));
    roots.push(root);
    const file = path.join(root, "bakers-regular-2026-08-08.json");
    await writeFile(file, JSON.stringify({ deals: [{ item: "Eggs", size: "dozen", current_price: 1.99, as_of: "2026-08-08" }] }));
    await expect(readFreshRegularCapture(file, {
      now: new Date("2026-08-09T18:00:00.000Z"),
      requiredDate: "2026-08-09",
    })).rejects.toThrow("did not capture the required production date");
  });
});
