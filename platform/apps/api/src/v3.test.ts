import { describe, expect, it } from "vitest";
import { restoreDrillRecordSchema } from "@thriftycrew/contracts";
import { wilsonInterval } from "./accuracy";
import { mayShowFreeBadge } from "./ghost-reconciliation";
import { storeCoverageFloor } from "./release-guards";

describe("out-of-band accuracy reporting", () => {
  it("computes the standard 95% Wilson interval without treating cannot-tell as a verdict", () => {
    const interval = wilsonInterval(90, 100);
    expect(interval?.low).toBeCloseTo(0.8256, 3);
    expect(interval?.high).toBeCloseTo(0.9448, 3);
    expect(wilsonInterval(0, 0)).toBeNull();
  });
});

describe("Ghost rotation badge truth", () => {
  it("only allows a badge when release intent and verified Ghost truth are both public", () => {
    expect(mayShowFreeBadge("public", "public")).toBe(true);
    expect(mayShowFreeBadge("public", "paid")).toBe(false);
    expect(mayShowFreeBadge("paid", "public")).toBe(false);
  });
});

describe("first native coverage baseline", () => {
  it("uses the authored direct baseline only for the bridge-to-native cutover", () => {
    expect(storeCoverageFloor(345, 276, true)).toBe(276);
    expect(storeCoverageFloor(345, 276, false)).toBe(310);
    expect(storeCoverageFloor(345, undefined, true)).toBe(310);
  });
});

describe("restore drill evidence contract", () => {
  const base = {
    id: "restore_2026-08-09",
    backupId: "backup_d1-backup-manual",
    scratchDatabaseId: "6360833f-056c-4c77-90de-4a56b7d7fa3a",
    dumpSha256: "a".repeat(64),
    startedAt: "2026-08-09T21:00:00.000Z",
    evidence: { tableCount: 49 },
  };

  it("requires finish evidence for a passed or failed drill", () => {
    expect(restoreDrillRecordSchema.safeParse({ ...base, status: "passed" }).success).toBe(false);
    expect(restoreDrillRecordSchema.safeParse({ ...base, status: "passed", finishedAt: "2026-08-09T21:05:00.000Z" }).success).toBe(true);
  });

  it("rejects a finish timestamp before the drill started", () => {
    expect(restoreDrillRecordSchema.safeParse({ ...base, status: "failed", finishedAt: "2026-08-09T20:59:00.000Z" }).success).toBe(false);
  });
});
