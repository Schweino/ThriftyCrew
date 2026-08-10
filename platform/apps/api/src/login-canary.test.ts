import { describe, expect, it } from "vitest";
import { assertLoginCanaryEvidenceHasNoEmail } from "./login-canary";

describe("login canary privacy", () => {
  it("allows only pseudonymous Ghost membership evidence", () => {
    expect(() => assertLoginCanaryEvidenceHasNoEmail({ ghostId: "member_123", tags: ["free"], url: "https://example.test/member" })).not.toThrow();
  });

  it("rejects email fields and embedded addresses", () => {
    expect(() => assertLoginCanaryEvidenceHasNoEmail({ memberEmail: "hidden" })).toThrow(/email field/);
    expect(() => assertLoginCanaryEvidenceHasNoEmail({ signal: "signed in as person@example.test" })).toThrow(/email address/);
  });
});
