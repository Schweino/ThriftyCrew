import { describe, expect, it } from "vitest";
import { checkpointPassedMatchRun, matchRunCheckpointMaterial } from "./match-run-checkpoint";

const prior = {
  id: "match_prior", batch_id: "batch_1", configuration_id: "configuration_1", input_hash: "a".repeat(64),
  status: "passed", product_count: 10, matched_count: 7, unmatched_count: 2, collision_count: 0,
  aisle_rejected_count: 1, detail_json: "{}",
};

describe("match-run integrity checkpoint", () => {
  it("binds a new checkpoint to the exact prior identity and current counts", () => {
    expect(matchRunCheckpointMaterial(prior, { products: 10, matched: 7 })).toEqual({
      schema: "match-run-integrity-checkpoint-v1", priorRunId: "match_prior", priorInputHash: "a".repeat(64),
      batchId: "batch_1", configurationId: "configuration_1", productCount: 10, matchedCount: 7,
    });
  });

  it("fails closed when current products or decisions drifted", () => {
    expect(() => matchRunCheckpointMaterial(prior, { products: 11, matched: 7 })).toThrow(/not currently integrity-true/);
    expect(() => matchRunCheckpointMaterial(prior, { products: 10, matched: 6 })).toThrow(/not currently integrity-true/);
  });

  it("rejects failed, colliding, or internally inconsistent prior runs", () => {
    expect(() => matchRunCheckpointMaterial({ ...prior, status: "failed" }, { products: 10, matched: 7 })).toThrow(/passed prior/);
    expect(() => matchRunCheckpointMaterial({ ...prior, collision_count: 1, unmatched_count: 1 }, { products: 10, matched: 7 })).toThrow(/collision-free/);
    expect(() => matchRunCheckpointMaterial({ ...prior, unmatched_count: 3 }, { products: 10, matched: 7 })).toThrow(/internally inconsistent/);
  });

  it("uses only immutable reads plus one insert and validates an idempotent identity", async () => {
    const statements: string[] = [];
    let insertBindings: unknown[] = [];
    const db = { prepare(sql: string) {
      statements.push(sql);
      return { bind(...bindings: unknown[]) {
        if (sql.includes("INSERT INTO match_runs")) insertBindings = bindings;
        return {
          first: async () => {
            if (sql.includes("FROM match_runs run")) return prior;
            if (sql.includes("COUNT(DISTINCT product.id) AS products")) return { products: 10, matched: 7 };
            if (sql.includes("FROM match_runs WHERE id")) return {
              batch_id: insertBindings[1], configuration_id: insertBindings[2], input_hash: insertBindings[3], status: "passed",
              product_count: insertBindings[4], matched_count: insertBindings[5], unmatched_count: insertBindings[6],
              collision_count: 0, aisle_rejected_count: insertBindings[7],
            };
            return null;
          },
          run: async () => ({ meta: { changes: 0 } }),
        };
      } };
    } } as unknown as D1Database;
    await expect(checkpointPassedMatchRun(db, "batch_1")).resolves.toMatchObject({
      batchId: "batch_1", priorRunId: "match_prior", status: "passed", idempotent: true,
    });
    expect(statements.some((sql) => /\b(?:UPDATE|DELETE)\b/.test(sql))).toBe(false);
    expect(statements.filter((sql) => sql.includes("INSERT INTO match_runs"))).toHaveLength(1);
  });

  it("fails if integrity changes between recomputation and the guarded insert", async () => {
    const db = { prepare(sql: string) { return { bind() { return {
      first: async () => sql.includes("FROM match_runs run") ? prior
        : sql.includes("COUNT(DISTINCT product.id) AS products") ? { products: 10, matched: 7 } : null,
      run: async () => ({ meta: { changes: 0 } }),
    }; } }; } } as unknown as D1Database;
    await expect(checkpointPassedMatchRun(db, "batch_1")).rejects.toThrow(/lost integrity before its immutable insert/);
  });
});
