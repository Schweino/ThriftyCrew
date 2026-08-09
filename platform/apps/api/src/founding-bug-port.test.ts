import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, expect, it } from "vitest";

interface PortCase {
  id: string;
  disposition: "ported_test" | "ported_guard" | "structurally_eliminated" | "pending";
  proof: string;
  reason: string;
}

describe("legacy founding-bug port", () => {
  it("has a concrete V3 proof for every inventoried failure class", async () => {
    const platformRoot = path.resolve(import.meta.dirname, "../../..");
    const manifest = JSON.parse(await readFile(path.join(platformRoot, "docs/founding-bug-port.json"), "utf8")) as { cases: PortCase[] };
    expect(manifest.cases.length).toBeGreaterThanOrEqual(60);
    expect(new Set(manifest.cases.map((item) => item.id)).size).toBe(manifest.cases.length);
    expect(manifest.cases.filter((item) => item.disposition === "pending")).toEqual([]);
    for (const item of manifest.cases) {
      expect(item.reason.length, item.id).toBeGreaterThan(20);
      await expect(readFile(path.join(platformRoot, item.proof), "utf8"), item.id).resolves.not.toHaveLength(0);
    }
  });
});
