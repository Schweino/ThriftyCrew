import { describe, expect, it } from "vitest";
import { RESTORE_MULTIPART_PART_BYTES, RESTORE_SOURCE_PART_BYTES } from "./restore-policy";

describe("restore normalization partitioning", () => {
  it("keeps CPU-bounded source chunks while honoring R2's multipart minimum", () => {
    expect(RESTORE_SOURCE_PART_BYTES).toBe(1 * 1024 * 1024);
    expect(RESTORE_MULTIPART_PART_BYTES).toBe(5 * 1024 * 1024);
    expect(RESTORE_MULTIPART_PART_BYTES).toBeGreaterThanOrEqual(RESTORE_SOURCE_PART_BYTES);
  });
});
