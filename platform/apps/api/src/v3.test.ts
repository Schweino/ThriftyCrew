import { describe, expect, it } from "vitest";
import { wilsonInterval } from "./accuracy";
import { mayShowFreeBadge } from "./ghost-reconciliation";

describe("out-of-band accuracy reporting", () => {
  it("computes the standard 95% Wilson interval without treating cannot-tell as a verdict", () => {
    const interval = wilsonInterval(90, 100);
    expect(interval?.low).toBeCloseTo(0.8256, 3);
    expect(interval?.high).toBeCloseTo(0.9448, 3);
    expect(wilsonInterval(0, 0)).toBeNull();
  });
});

describe("Ghost rotation badge truth", () => {
  it("only allows a badge when release intent and verified Ghost truth are both public", () => {
    expect(mayShowFreeBadge("public", "public")).toBe(true);
    expect(mayShowFreeBadge("public", "paid")).toBe(false);
    expect(mayShowFreeBadge("paid", "public")).toBe(false);
  });
});
