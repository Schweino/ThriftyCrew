import { describe, expect, it } from "vitest";
import { emptyRestoreCounts, inspectSqlInsert, normalizeCaptureBatchLine } from "./restore-normalization";

describe("D1 restore normalization", () => {
  it("parses D1 inserts without being confused by JSON commas and escaped quotes", () => {
    expect(inspectSqlInsert(
      `INSERT INTO "releases" ("id","input_manifest_json","input_hash") VALUES('rel_1','{"label":"Brad''s, list"}','abc123');`,
    )).toEqual({
      table: "releases",
      columns: ["id", "input_manifest_json", "input_hash"],
      values: ["rel_1", `{"label":"Brad's, list"}`, "abc123"],
    });
  });

  it("defers only non-null terminal capture supersession references", () => {
    const source = `INSERT INTO "capture_batches" ("id","status","superseded_by") VALUES('batch_old','superseded','batch_new');`;
    expect(normalizeCaptureBatchLine(source)).toEqual({
      line: `INSERT INTO "capture_batches" ("id","status","superseded_by") VALUES('batch_old','superseded',NULL);`,
      deferredUpdate: `UPDATE "capture_batches" SET "superseded_by"='batch_new' WHERE "id"='batch_old';`,
    });
    const alreadyNull = `INSERT INTO "capture_batches" ("id","status","superseded_by") VALUES('batch_new','promoted',NULL);`;
    expect(normalizeCaptureBatchLine(alreadyNull)).toEqual({ line: alreadyNull });
  });

  it("creates a complete zeroed count ledger", () => {
    expect(emptyRestoreCounts()).toEqual({
      capture_batches: 0,
      observations: 0,
      products: 0,
      releases: 0,
      release_cells: 0,
      job_runs: 0,
    });
  });
});
