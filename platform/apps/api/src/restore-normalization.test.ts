import { describe, expect, it } from "vitest";
import {
  countSqlInsertLines,
  emptyRestoreCounts,
  hasUtf8LineExceeding,
  inspectSqlInsert,
  normalizeCaptureBatchLine,
  restoreChunkNeedsOversizedScan,
  summarizeHomogeneousSqlInsertChunk,
  utf8LengthExceeds,
} from "./restore-normalization";

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

  it("measures oversized statements in UTF-8 bytes", () => {
    expect(utf8LengthExceeds("a".repeat(90_001), 90_000)).toBe(true);
    expect(utf8LengthExceeds("😀".repeat(22_501), 90_000)).toBe(true);
    expect(utf8LengthExceeds("a".repeat(90_000), 90_000)).toBe(false);
  });

  it("counts only SQL insert line prefixes for the requested table", () => {
    const text = [
      'INSERT INTO "observations" ("id") VALUES(\'one\');',
      'INSERT INTO "products" ("id") VALUES(\'INSERT INTO "observations" fake\');',
      'INSERT INTO "observations" ("id") VALUES(\'two\');',
      "",
    ].join("\n");
    expect(countSqlInsertLines(text, "observations")).toBe(2);
    expect(countSqlInsertLines(text, "products")).toBe(1);
  });

  it("detects an oversized UTF-8 line without treating the whole chunk as one statement", () => {
    expect(hasUtf8LineExceeding("short\nrows\n", 10)).toBe(false);
    expect(hasUtf8LineExceeding(`short\n${"é".repeat(6)}\n`, 10)).toBe(true);
  });

  it("reserves expensive oversized scans for payload table blocks", () => {
    expect(restoreChunkNeedsOversizedScan('INSERT INTO "observations" ("id") VALUES(\'one\');')).toBe(false);
    expect(restoreChunkNeedsOversizedScan('INSERT INTO "release_payloads" ("payload_json") VALUES(\'{}\');')).toBe(true);
  });

  it("summarizes homogeneous D1 table blocks without scanning unrelated tables", () => {
    expect(summarizeHomogeneousSqlInsertChunk([
      'INSERT INTO "match_rules" ("id") VALUES(\'one\');',
      'INSERT INTO "match_rules" ("id") VALUES(\'two\');',
      "",
    ].join("\n"))).toEqual({ table: "match_rules", rows: 2 });
    expect(summarizeHomogeneousSqlInsertChunk([
      'INSERT INTO "products" ("id") VALUES(\'one\');',
      'INSERT INTO "observations" ("id") VALUES(\'two\');',
      "",
    ].join("\n"))).toBeNull();
  });
});
