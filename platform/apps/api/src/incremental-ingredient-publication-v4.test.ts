import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import { assertFinalizeBinding } from "./incremental-ingredient-publication";

const hash = "a".repeat(64);
const clean = () => ({ publicVersionId: "pub", pricingJobId: "job",
  version: { state: "staged", currentPublicVersionId: "pub", pricingJobId: "job", snapshotHash: hash },
  rowCount: 7, storeCount: 7, jobState: "ready_to_publish", operationalState: "ready_to_publish",
  originProofs: [{ origin: "https://worker.test", expectedHash: hash, observedHash: hash }, { origin: "https://public.test", expectedHash: hash, observedHash: hash }] });

describe("V4 incremental publication fences", () => {
  it("rejects substituted pointers, jobs, hashes, and incomplete rows", () => {
    expect(() => assertFinalizeBinding(clean())).not.toThrow();
    expect(() => assertFinalizeBinding({ ...clean(), pricingJobId: "attacker" })).toThrow(/binding/);
    expect(() => assertFinalizeBinding({ ...clean(), rowCount: 6 })).toThrow(/seven/);
    const bad = clean(); bad.originProofs[0]!.observedHash = "b".repeat(64);
    expect(() => assertFinalizeBinding(bad)).toThrow(/hash/);
    expect(() => assertFinalizeBinding({ ...clean(), jobState: "public_verified" })).toThrow(/resolution-ready/);
  });

  it("contains no global release, Git, worktree, deployment, or rematch dependency", async () => {
    const source = await readFile(new URL("./incremental-ingredient-publication.ts", import.meta.url), "utf8");
    for (const forbidden of ["buildNativeRelease", "rematchPromotedBatches", "publishIngredientMicrobatch", "git ", "worktree", "deployConfiguration", "current_releases"]) expect(source).not.toContain(forbidden);
  });
});
