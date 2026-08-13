import { describe, expect, it } from "vitest";
import { assertChatGptAuthDocument, codexStrictOutputSchema, normalizeCodexStructuredOutput, stripCodexOptionalNulls, subscriptionEnvironment } from "./codex-subscription";

describe("Codex subscription execution boundary", () => {
  it("accepts ChatGPT OAuth auth without an API key", () => {
    expect(() => assertChatGptAuthDocument({ auth_mode: "chatgpt", OPENAI_API_KEY: null, tokens: { access_token: "fixture" } })).not.toThrow();
  });

  it("rejects API-key auth and mixed auth", () => {
    expect(() => assertChatGptAuthDocument({ auth_mode: "apikey", tokens: {} })).toThrow(/auth_mode=chatgpt/);
    expect(() => assertChatGptAuthDocument({ auth_mode: "chatgpt", OPENAI_API_KEY: "fixture", tokens: {} })).toThrow(/API key/);
  });

  it("strips every API billing variable from the child process", () => {
    expect(subscriptionEnvironment({ PATH: "fixture", OPENAI_API_KEY: "secret", CODEX_API_KEY: "secret", OPENAI_BASE_URL: "https://example.test" })).toEqual({ PATH: "fixture" });
  });

  it("adapts optional properties to Codex strict schema and removes only injected nulls", () => {
    const schema = {
      type: "object",
      properties: {
        requiredValue: { type: ["string", "null"] },
        optionalValue: { type: "string" },
      },
      required: ["requiredValue"],
      additionalProperties: false,
    };
    expect(codexStrictOutputSchema(schema)).toMatchObject({
      required: ["requiredValue", "optionalValue"],
      properties: { optionalValue: { anyOf: [{ type: "string" }, { type: "null" }] } },
    });
    expect(stripCodexOptionalNulls({ requiredValue: null, optionalValue: null }, schema)).toEqual({ requiredValue: null });
  });

  it("collapses only exact duplicate mapper component references before contract validation", () => {
    const output = {
      requestId: "request_one",
      recipes: [{
        mealComponents: [
          { role: "main", commodityIds: ["chicken", "oil", "chicken"] },
          { role: "substantial-accompaniment", commodityIds: ["rice", "beans"] },
        ],
      }],
    };
    expect(normalizeCodexStructuredOutput(output, "recipe-map-v2")).toEqual({
      requestId: "request_one",
      recipes: [{
        mealComponents: [
          { role: "main", commodityIds: ["chicken", "oil"] },
          { role: "substantial-accompaniment", commodityIds: ["rice", "beans"] },
        ],
      }],
    });
    expect(normalizeCodexStructuredOutput(output, "content-items-v2")).toBe(output);
  });

  it("removes product and price residue only from non-priced ingredient store checks", () => {
    const output = {
      stores: [
        { outcome: "priced", productName: "Extra firm tofu", packagePriceMinor: 249, validFrom: null },
        { outcome: "ambiguous", productName: "Possible tofu", packagePriceMinor: 199, sourceUrl: "https://example.test" },
      ],
    };
    expect(normalizeCodexStructuredOutput(output, "ingredient-price-research-v1")).toMatchObject({
      stores: [
        { outcome: "priced", productName: "Extra firm tofu", packagePriceMinor: 249 },
        { outcome: "ambiguous", productName: null, packagePriceMinor: null, sourceUrl: "https://example.test" },
      ],
    });
  });
});
