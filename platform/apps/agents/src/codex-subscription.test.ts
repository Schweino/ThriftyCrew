import { describe, expect, it } from "vitest";
import { assertChatGptAuthDocument, codexStrictOutputSchema, stripCodexOptionalNulls, subscriptionEnvironment } from "./codex-subscription";

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
});
