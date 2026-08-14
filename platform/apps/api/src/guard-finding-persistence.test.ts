import { describe, expect, it } from "vitest";
import { deduplicateGuardFindings, upsertGuardResult } from "./database";

describe("guard finding persistence", () => {
  it("collapses identical finding keys deterministically while retaining every distinct variant", () => {
    const findings = deduplicateGuardFindings([
      { key: "duplicate-price", message: "Price differs", evidence: { store: "B", price: 299 } },
      { key: "other", message: "Other failure", evidence: { row: 1 } },
      { key: "duplicate-price", message: "Price differs", evidence: { store: "A", price: 199 } },
      { key: "duplicate-price", message: "Price differs", evidence: { store: "A", price: 199 } },
    ]);

    expect(findings.map((finding) => finding.key)).toEqual(["duplicate-price", "other"]);
    expect(findings[0]).toEqual({
      key: "duplicate-price",
      message: "Price differs",
      evidence: {
        deduplicatedFindingCount: 3,
        distinctVariantCount: 2,
        variants: [
          { message: "Price differs", evidence: { store: "A", price: 199 } },
          { message: "Price differs", evidence: { store: "B", price: 299 } },
        ],
      },
    });
    expect(findings[1]).toEqual({ key: "other", message: "Other failure", evidence: { row: 1 } });
  });

  it("is idempotent when normalized findings are submitted again", () => {
    const once = deduplicateGuardFindings([
      { key: "same", message: "Failure", evidence: { row: 1 } },
      { key: "same", message: "Failure", evidence: { row: 1 } },
    ]);
    expect(deduplicateGuardFindings(once)).toEqual(once);
  });

  it("writes one conflict-safe finding row for a duplicate key", async () => {
    const batches: Array<Array<{ sql: string; bindings: unknown[] }>> = [];
    const db = {
      prepare(sql: string) {
        const statement = {
          sql, bindings: [] as unknown[],
          bind(...bindings: unknown[]) { this.bindings = bindings; return this; },
          async first() { return sql.includes("guard_definitions") ? { severity: "hard" } : null; },
        };
        return statement;
      },
      async batch(statements: Array<{ sql: string; bindings: unknown[] }>) { batches.push(statements); return []; },
    } as unknown as D1Database;

    await upsertGuardResult(db, "release-1", {
      guardId: "release-integrity", status: "fail", eligibleCount: 2, examinedCount: 2, detail: {},
      findings: [
        { key: "same-row", message: "Mismatch", evidence: { value: 1 } },
        { key: "same-row", message: "Mismatch", evidence: { value: 2 } },
      ],
    });

    const statements = batches.flat();
    const findingWrites = statements.filter((statement) => statement.sql.includes("INSERT INTO guard_findings"));
    expect(findingWrites).toHaveLength(1);
    expect(findingWrites[0]!.sql).toContain("ON CONFLICT(result_id, finding_key) DO UPDATE");
    expect(statements.find((statement) => statement.sql.includes("INSERT INTO guard_results"))?.bindings[6]).toBe(1);
  });
});
