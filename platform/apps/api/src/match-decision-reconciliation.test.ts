import { describe, expect, it } from "vitest";
import { reconcileInactiveConfigurationDecisions } from "./match-decision-reconciliation";

function database(effectiveBatches: number, missingActiveMatches: number) {
  const updates: unknown[][] = [];
  const db = {
    prepare(sql: string) {
      if (sql.startsWith("SELECT id FROM configuration_versions")) {
        return { first: async () => ({ id: "cfg_new" }) };
      }
      if (sql.includes("UPDATE match_decisions")) {
        return {
          bind: (...values: unknown[]) => ({
            run: async () => {
              updates.push(values);
              return { meta: { changes: 17 } };
            },
          }),
        };
      }
      if (sql.includes("WITH ranked AS")) {
        return {
          bind: () => ({ first: async () => ({ effective_batches: effectiveBatches, missing_active_matches: missingActiveMatches }) }),
        };
      }
      throw new Error(`unexpected SQL: ${sql}`);
    },
  } as unknown as D1Database;
  return { db, updates };
}

describe("inactive configuration decision reconciliation", () => {
  it("retires old active decisions only after every effective batch has a passing active match", async () => {
    const { db, updates } = database(7, 0);
    await expect(reconcileInactiveConfigurationDecisions(db, "2026-08-13T19:00:00.000Z")).resolves.toEqual({
      activeConfigurationId: "cfg_new",
      effectiveBatches: 7,
      missingActiveMatches: 0,
      superseded: 17,
      ready: true,
    });
    expect(updates).toEqual([["2026-08-13T19:00:00.000Z", "cfg_new"]]);
  });

  it("preserves the last usable decision set during a partial rematch", async () => {
    const { db, updates } = database(7, 1);
    await expect(reconcileInactiveConfigurationDecisions(db)).resolves.toMatchObject({ ready: false, superseded: 0 });
    expect(updates).toHaveLength(0);
  });

  it("does not retire decisions when there is no effective capture snapshot", async () => {
    const { db, updates } = database(0, 0);
    await expect(reconcileInactiveConfigurationDecisions(db)).resolves.toMatchObject({ ready: false, superseded: 0 });
    expect(updates).toHaveLength(0);
  });
});
