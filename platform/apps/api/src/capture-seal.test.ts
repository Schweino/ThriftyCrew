import { describe, expect, it } from "vitest";
import { buildCaptureTermInserts } from "./capture-seal";

describe("capture seal term inserts", () => {
  it("packs a full 528-term capture below D1's 100-bind statement limit", () => {
    const terms = Array.from({ length: 528 }, (_, ordinal) => ({
      termKey: `term-${ordinal}`,
      ordinal,
      outcome: "success",
      rowCount: ordinal + 1,
    }));

    const inserts = buildCaptureTermInserts("batch-test", terms);

    expect(inserts).toHaveLength(33);
    expect(Math.max(...inserts.map((insert) => insert.bindings.length))).toBe(96);
    expect(inserts.reduce((rows, insert) => rows + insert.bindings.length / 6, 0)).toBe(528);
    expect(inserts[0]?.bindings.slice(0, 6)).toEqual(["batch-test", "term-0", 0, "success", 1, null]);
    expect(inserts.at(-1)?.bindings.slice(-6)).toEqual(["batch-test", "term-527", 527, "success", 528, null]);
  });
});
