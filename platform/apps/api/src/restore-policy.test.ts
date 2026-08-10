import { describe, expect, it } from "vitest";
import { RESTORE_MULTIPART_PART_BYTES, RESTORE_SOURCE_PART_BYTES, padRestoreMultipartPart } from "./restore-policy";

describe("restore normalization partitioning", () => {
  it("keeps CPU-bounded source chunks while honoring R2's multipart minimum", () => {
    expect(RESTORE_SOURCE_PART_BYTES).toBe(2 * 1024 * 1024);
    expect(RESTORE_MULTIPART_PART_BYTES).toBe(5 * 1024 * 1024);
    expect(RESTORE_MULTIPART_PART_BYTES).toBeGreaterThanOrEqual(RESTORE_SOURCE_PART_BYTES);
  });

  it("pads encoded SQL with bytes instead of rebuilding a multi-megabyte string", () => {
    const source = new TextEncoder().encode("INSERT INTO t VALUES (1);");
    const result = padRestoreMultipartPart(source, 64);

    expect(result).toHaveLength(64);
    expect(new TextDecoder().decode(result.subarray(0, source.byteLength + 1))).toBe("INSERT INTO t VALUES (1);\n");
    expect(Array.from(result.subarray(source.byteLength + 1))).toEqual(Array(64 - source.byteLength - 1).fill(0x20));
  });

  it("rejects a part that cannot fit its SQL separator", () => {
    expect(() => padRestoreMultipartPart(new TextEncoder().encode("abcd"), 4)).toThrow(/exceeds/);
  });
});
