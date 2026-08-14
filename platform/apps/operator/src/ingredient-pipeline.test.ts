import { describe, expect, it } from "vitest";
import { ingredientQaFailureAction, isIdempotentQaResumeConflict } from "./ingredient-pipeline";

describe("ingredient QA failure routing", () => {
  it.each([
    "independent pass found an eligible exact candidate",
    "independent verifier found an eligible exact candidate in the repeated result envelope",
    "independent verification does not reproduce the frozen winner",
    "independent verifier did not reproduce the frozen winner identity, size, and price",
  ])("returns capture conflicts to a fresh producer generation: %s", (reason) => {
    expect(ingredientQaFailureAction(new Error(reason))).toBe("reject_to_capture");
  });

  it.each([
    "source throttled",
    "independent pass did not reproduce complete no-match coverage",
    "network timeout",
  ])("keeps operational failures on the bounded retry lane: %s", (reason) => {
    expect(ingredientQaFailureAction(reason)).toBe("retry");
  });

  it("only treats a lease-fence conflict as an idempotent QA resume", () => {
    expect(isIdempotentQaResumeConflict("POST returned 409: QA completion rejected by lease fence or lane boundary")).toBe(true);
    expect(isIdempotentQaResumeConflict("POST returned 409: independent verifier found an eligible exact candidate")).toBe(false);
  });
});
