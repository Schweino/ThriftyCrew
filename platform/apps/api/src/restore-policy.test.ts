import { describe, expect, it } from "vitest";
import { RESTORE_MULTIPART_PART_BYTES, RESTORE_SOURCE_PART_BYTES, padRestoreMultipartPart } from "./restore-policy";

describe("restore normalization partitioning", () => {
  it("keeps CPU-bounded source chunks while honoring R2's multipart minimum", () => {
    expect(RESTORE_SOURCE_PART_BYTES).toBe(5 * 1024 * 1024);
    expect(RESTORE_MULTIPART_PART_BYTES).toBe((11 * 1024 * 1024) / 2);
    expect(RESTORE_MULTIPART_PART_BYTES).toBeGreaterThanOrEqual(RESTORE_SOURCE_PART_BYTES);
  });

  it("pads encoded SQL with bounded no-op statements", () => {
    const source = new TextEncoder().encode("INSERT INTO t VALUES (1);");
    const result = padRestoreMultipartPart(source, 64);

    expect(result).toHaveLength(64);
    expect(new TextDecoder().decode(result.subarray(0, source.byteLength + 1))).toBe("INSERT INTO t VALUES (1);\n");
    expect(new TextDecoder().decode(result.subarray(source.byteLength + 1))).toMatch(/^-- +\nSELECT 1;\n$/);
  });

  it("leaves a part at or above the multipart minimum unchanged", () => {
    expect(new TextDecoder().decode(padRestoreMultipartPart(new TextEncoder().encode("abcd"), 4))).toBe("abcd");
    expect(() => padRestoreMultipartPart(new TextEncoder().encode("abcde"), 4)).toThrow(/exceeds/);
  });

  it("keeps every padding statement below the D1 statement ceiling", () => {
    const result = new TextDecoder().decode(padRestoreMultipartPart(new Uint8Array(), 100_000));
    const statements = result.split("SELECT 1;\n").filter(Boolean);
    expect(statements.length).toBe(4);
    expect(Math.max(...statements.map((statement) => new TextEncoder().encode(statement).byteLength))).toBeLessThanOrEqual((32 * 1024) + 12);
  });
});
