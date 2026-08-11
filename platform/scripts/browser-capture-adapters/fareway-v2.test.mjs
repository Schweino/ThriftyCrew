import { describe, expect, it } from "vitest";
import { validatedRegularPrice } from "./fareway-v2.mjs";

describe("Fareway regular-price semantics", () => {
  it("keeps only a genuine higher comparison price", () => {
    expect(validatedRegularPrice(219, 299)).toBe(299);
    expect(validatedRegularPrice(219, 219)).toBeUndefined();
    expect(validatedRegularPrice(219, 117)).toBeUndefined();
    expect(validatedRegularPrice(219, undefined)).toBeUndefined();
  });
});
