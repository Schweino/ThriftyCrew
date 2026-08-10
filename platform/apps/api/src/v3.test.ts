import { describe, expect, it } from "vitest";
import { captureBatchAbandonSchema, entitlementVerificationRecordSchema, evidenceGateRecordSchema, restoreDrillRecordSchema } from "@thriftycrew/contracts";
import { createAccuracyDraw, readAccuracyDraw, wilsonInterval } from "./accuracy";
import { mayShowFreeBadge } from "./ghost-reconciliation";
import { releaseCaptureEvictionSql, storeCoverageFloor } from "./release-guards";
import { memberStatusHtml } from "./member-status";
import { engineMayWriteCaptureSource } from "./capture-authorization";
import { snapshotIncludesRawCandidates } from "./engine-snapshot";

describe("capture role/source authorization", () => {
  it("allows GitHub engine writes only for migration bridges and approved direct headless sources", () => {
    expect(engineMayWriteCaptureSource("legacy-bakers", "legacy_bridge")).toBe(true);
    expect(engineMayWriteCaptureSource("direct-bakers-headless", "api")).toBe(true);
    expect(engineMayWriteCaptureSource("direct-family-fare-headless", "freshop")).toBe(true);
    expect(engineMayWriteCaptureSource("direct-walmart-browser", "browser")).toBe(false);
    expect(engineMayWriteCaptureSource("direct-walmart-headless", "browser")).toBe(false);
    expect(engineMayWriteCaptureSource("unapproved-source", "api")).toBe(false);
  });
});

describe("out-of-band accuracy reporting", () => {
  it("computes the standard 95% Wilson interval without treating cannot-tell as a verdict", () => {
    const interval = wilsonInterval(90, 100);
    expect(interval?.low).toBeCloseTo(0.8256, 3);
    expect(interval?.high).toBeCloseTo(0.9448, 3);
    expect(wilsonInterval(0, 0)).toBeNull();
  });

  it("returns the existing market/seed/protocol draw after a release cutover", async () => {
    let statements = 0;
    const db = {
      prepare(sql: string) {
        statements += 1;
        expect(sql).toContain("market_id = ?1 AND seed = ?2 AND protocol_version = ?3");
        return {
          bind() { return this; },
          async first() { return { id: "accuracy_existing", sampled_count: 100 }; },
        };
      },
    } as unknown as D1Database;
    await expect(createAccuracyDraw(db, {
      marketId: "omaha",
      seed: "week-2026-08-09",
      protocolVersion: "blind-cell-v1",
      sampleSize: 100,
      dueAt: "2026-08-16T21:00:00.000Z",
    })).resolves.toEqual({ drawId: "accuracy_existing", sampled: 100, idempotent: true });
    expect(statements).toBe(1);
  });

  it("keeps the reviewer contract independent of mutable public board formatting", async () => {
    const sql: string[] = [];
    const db = {
      prepare(statement: string) {
        sql.push(statement);
        return {
          bind() { return this; },
          async first() { return { id: "draw" }; },
          async all() { return { results: [] }; },
        };
      },
    } as unknown as D1Database;
    await readAccuracyDraw(db, "draw", true);
    expect(sql[1]).toContain("pv.size_text AS raw_size_text");
    expect(sql[1]).toContain("o.purchase_price_minor");
    expect(sql[1]).toContain("o.captured_at");
  });
});

describe("Ghost rotation badge truth", () => {
  it("only allows a badge when release intent and verified Ghost truth are both public", () => {
    expect(mayShowFreeBadge("public", "public")).toBe(true);
    expect(mayShowFreeBadge("public", "paid")).toBe(false);
    expect(mayShowFreeBadge("paid", "public")).toBe(false);
  });
});

describe("browser-visible member status", () => {
  it("renders only the entitlement decision and is usable on a narrow screen", () => {
    const html = memberStatusHtml({ state: "cookie_expired", authenticated: false, tier: "anonymous", mayUseProtectedTools: false });
    expect(html).toContain("cookie expired");
    expect(html).toContain("Paid tools are locked.");
    expect(html).toContain('name="viewport"');
    expect(html).not.toContain("email");
    expect(html).not.toContain("session/signout");
    expect(memberStatusHtml({ state: "free", authenticated: true, tier: "free", mayUseProtectedTools: false })).toContain("session/signout");
    expect(memberStatusHtml({ state: "signed_out", authenticated: false, tier: "anonymous", mayUseProtectedTools: false })).toContain("session/resume");
  });
});

describe("first native coverage baseline", () => {
  it("uses the authored direct baseline only for the bridge-to-native cutover", () => {
    expect(storeCoverageFloor(345, 276, true)).toBe(276);
    expect(storeCoverageFloor(345, 276, false)).toBe(310);
    expect(storeCoverageFloor(345, undefined, true)).toBe(310);
  });
});

describe("capture eviction guard", () => {
  it("bounds complete-capture protection to the immutable release snapshot", () => {
    expect(releaseCaptureEvictionSql).toContain("FROM release_input_batches candidate_input");
    expect(releaseCaptureEvictionSql).toContain("candidate_input.release_id = ?1");
    expect(releaseCaptureEvictionSql).not.toContain("candidate_batch.status IN");
  });
});

describe("engine snapshot profiles", () => {
  it("omits recipe-only raw candidates from parity snapshots", () => {
    expect(snapshotIncludesRawCandidates("parity")).toBe(false);
    expect(snapshotIncludesRawCandidates("release")).toBe(true);
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

describe("live evidence contracts", () => {
  it("requires a meaningful reason before an open capture may be abandoned", () => {
    expect(captureBatchAbandonSchema.safeParse({ reason: "test" }).success).toBe(false);
    expect(captureBatchAbandonSchema.safeParse({ reason: "superseded one-off operator fixture" }).success).toBe(true);
  });

  it("rejects unknown completion gates", () => {
    expect(evidenceGateRecordSchema.safeParse({
      id: "evidence_1",
      gate: "made-up-gate",
      periodKey: "2026-08-09",
      sourceRef: "release_1",
      status: "pass",
      observedAt: "2026-08-09T21:00:00.000Z",
      evidence: {},
    }).success).toBe(false);
  });

  it("accepts every entitlement state named by the V3 adapter", () => {
    for (const state of ["anonymous", "free", "paid", "expired", "cancelled", "signed_out", "cookie_expired"]) {
      expect(entitlementVerificationRecordSchema.safeParse({
        id: `entitlement_${state}`,
        adapterVersion: "ghost-v1",
        state,
        clientKind: "desktop-chrome",
        status: "pass",
        verifiedAt: "2026-08-09T21:00:00.000Z",
        evidence: {},
      }).success).toBe(true);
    }
  });
});
