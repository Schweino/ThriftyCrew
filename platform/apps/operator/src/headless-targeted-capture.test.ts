import { describe, expect, it } from "vitest";
import { claimSearchTerms, headlessPriceMinor, headlessPriceSemantics } from "./headless-targeted-capture";

describe("headless targeted store capture", () => {
  it("accepts only unambiguous single-package prices", () => {
    expect(headlessPriceMinor("$3.49")).toBe(349);
    expect(headlessPriceMinor(3.49)).toBe(349);
    expect(headlessPriceMinor("4 for $5.00")).toBeNull();
    expect(headlessPriceMinor("$3.499")).toBeNull();
  });

  it("refuses a discounted price without a complete effective window", () => {
    expect(headlessPriceSemantics(299, 399)).toBeNull();
    expect(headlessPriceSemantics(299, 399, "2026-08-12T00:00:00.000Z", "2026-08-19T00:00:00.000Z"))
      .toMatchObject({ offerType: "sale", regularPriceMinor: 399 });
    expect(headlessPriceSemantics(399, 399)).toMatchObject({ offerType: "everyday" });
  });

  it("deduplicates locked query plans across a store microbatch", () => {
    const claims = [
      { commodity_proposal_json: JSON.stringify({ searchTerms: ["pistachios", "pistachio nuts"] }) },
      { commodity_proposal_json: JSON.stringify({ searchTerms: ["pistachios", "cinnamon sticks"] }) },
    ];
    expect(claimSearchTerms(claims as never)).toEqual(["pistachios", "pistachio nuts", "cinnamon sticks"]);
  });
});
