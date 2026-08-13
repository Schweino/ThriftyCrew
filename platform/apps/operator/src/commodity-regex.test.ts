import { describe, expect, it } from "vitest";
import { compileCommodityRegexPattern, normalizeCommodityRegexPattern, parseCatalogJson } from "./commodity-regex";

describe("commodity regex compatibility", () => {
  it("normalizes a leading PCRE case-insensitive flag because matching is already case-insensitive", () => {
    expect(normalizeCommodityRegexPattern("(?i)\\bfrozen\\b.{0,40}\\blima beans?\\b"))
      .toBe("\\bfrozen\\b.{0,40}\\blima beans?\\b");
    expect(compileCommodityRegexPattern("(?i)\\bfrozen\\b.{0,40}\\blima beans?\\b").test("Frozen Lima Beans"))
      .toBe(true);
  });

  it("preserves ordinary JavaScript patterns", () => {
    expect(normalizeCommodityRegexPattern("\\bpepitas?\\b")).toBe("\\bpepitas?\\b");
  });

  it("continues to reject malformed syntax", () => {
    expect(() => compileCommodityRegexPattern("(?q)invalid")).toThrow();
  });

  it("accepts authoritative JSON with or without a UTF-8 BOM", () => {
    expect(parseCatalogJson<{ ok: boolean }>("\uFEFF{\"ok\":true}")).toEqual({ ok: true });
    expect(parseCatalogJson<{ ok: boolean }>("{\"ok\":true}")).toEqual({ ok: true });
  });
});
