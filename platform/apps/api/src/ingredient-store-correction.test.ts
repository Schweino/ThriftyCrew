import { describe, expect, it } from "vitest";
import { reopenTerminalStoreCheckForCorrection } from "./ingredient-pricing-v2";

const terminal = {
  pricing_job_id: "job_1", gap_id: "gap_1", state: "qa_verified_priced",
  evidence_id: "evidence_1", qa_attestation_id: "qa_1",
  resolution_version_id: "resolution_1", gap_status: "ready_to_publish",
};

function correctionDb(overrides: { blocking?: { id: string; state: string } | null; changes?: number; check?: Record<string, unknown>; prior?: Record<string, unknown> } = {}) {
  const sql: string[] = [];
  return {
    sql,
    db: {
      prepare(statement: string) {
        sql.push(statement);
        return { bind() { return {
          first: async () => statement.includes("FROM ingredient_store_checks check_row") ? (overrides.check ?? terminal)
            : statement.includes("FROM ingredient_publication_batches batch") ? (overrides.blocking ?? null) : null,
        }; } };
      },
      batch: async (statements: unknown[]) => statements.map((_, index) => ({ meta: {
        changes: index === 3 || index === 7 ? (overrides.changes ?? 1) : 0,
      } })),
    } as unknown as D1Database,
  };
}

describe("terminal ingredient store-check correction", () => {
  it("preserves immutable evidence rows while invalidating every derived pointer behind compare-and-set fences", async () => {
    const fixture = correctionDb();
    await expect(reopenTerminalStoreCheckForCorrection(fixture.db, "check_1", {
      reason: "package multipack count was omitted from the normalized size",
      expectedEvidenceId: "evidence_1", expectedQaAttestationId: "qa_1",
    })).resolves.toMatchObject({ checkId: "check_1", state: "catalog_lookup", supersededResolutionVersionId: "resolution_1" });
    const mutationSql = fixture.sql.join("\n");
    expect(mutationSql).not.toMatch(/DELETE FROM ingredient_(?:evidence_refs|qa_attestations|resolution_versions)/);
    expect(mutationSql).toContain("DELETE FROM ingredient_current_resolutions");
    expect(mutationSql).toContain("evidence_id = ?5 AND qa_attestation_id = ?6");
    expect(mutationSql).toContain("state = 'catalog_lookup'");
    expect(mutationSql).toContain("failure_class = 'evidence_correction'");
  });

  it("refuses correction after publication has advanced beyond a safely replaceable sealed batch", async () => {
    const fixture = correctionDb({ blocking: { id: "batch_1", state: "validated" } });
    await expect(reopenTerminalStoreCheckForCorrection(fixture.db, "check_1", {
      reason: "package multipack count was omitted from the normalized size",
      expectedEvidenceId: "evidence_1", expectedQaAttestationId: "qa_1",
    })).rejects.toThrow(/corrective release/);
  });

  it("idempotently moves an already reopened correction through catalog lookup using its audit event fence", async () => {
    const detail = { supersededEvidenceId: "evidence_1", supersededQaAttestationId: "qa_1",
      supersededResolutionVersionId: "resolution_1" };
    const sql: string[] = [];
    const db = { prepare(statement: string) { sql.push(statement); return { bind() { return {
      first: async () => statement.includes("FROM ingredient_store_checks check_row")
        ? { ...terminal, state: "targeted_refresh", evidence_id: null, qa_attestation_id: null, last_error: "correction requested: package count" }
        : statement.includes("FROM pipeline_stage_events") ? { detail_json: JSON.stringify(detail) } : null,
      run: async () => ({ meta: { changes: 1 } }),
    }; } }; } } as unknown as D1Database;
    await expect(reopenTerminalStoreCheckForCorrection(db, "check_1", {
      reason: "package multipack count was omitted from the normalized size",
      expectedEvidenceId: "evidence_1", expectedQaAttestationId: "qa_1",
    })).resolves.toMatchObject({ state: "catalog_lookup", idempotent: true });
    expect(sql.join("\n")).toContain("stage = 'correction'");
  });

  it("fails closed when the durable aggregate or store-check fence is lost", async () => {
    const fixture = correctionDb({ changes: 0 });
    await expect(reopenTerminalStoreCheckForCorrection(fixture.db, "check_1", {
      reason: "package multipack count was omitted from the normalized size",
      expectedEvidenceId: "evidence_1", expectedQaAttestationId: "qa_1",
    })).rejects.toThrow(/durable state fence/);
  });
});
