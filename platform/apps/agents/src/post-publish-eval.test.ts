import { describe, expect, it } from "vitest";
import { evaluatePostPublishOutput } from "./post-publish-eval";

const input = { currentRelease: { id: "rel_ok" }, guards: { hard: "pass" }, ghost: "verified" };
const healthy = {
  version: 1,
  triageId: "rel_ok",
  diagnosis: "The supplied immutable release and guard evidence is healthy.",
  evidenceRefs: ["status:rel_ok"],
  blastRadius: { routes: [], releases: ["rel_ok"], stores: [], commodities: [], recipes: [] },
  implementation: ["No code or configuration change is required."],
  verification: ["Retain rel_ok and verify the supplied hard guard remains passing."],
  rollback: ["Retain rel_ok and revert only the reviewer change if validation regresses."],
  requiresOperator: false,
};

describe("post-publish production output evaluation", () => {
  it("accepts a complete healthy triage plan for the supplied release", () => {
    expect(evaluatePostPublishOutput(input, { decision: "pass", mustMention: ["rel_ok"] }, healthy)).toMatchObject({
      passed: true,
      detail: { schemaPassed: true, triageIdPassed: true, decisionPassed: true, missing: [] },
    });
  });

  it("rejects the empty rollback that failed the production reviewer", () => {
    expect(evaluatePostPublishOutput(input, { decision: "pass", mustMention: ["rel_ok"] }, { ...healthy, rollback: [] })).toMatchObject({
      passed: false,
      detail: { schemaPassed: false },
    });
  });

  it("does not grade a healthy no-change answer as a defect plan", () => {
    expect(evaluatePostPublishOutput(input, { decision: "plan", mustMention: ["guard"] }, healthy)).toMatchObject({
      passed: false,
      detail: { decisionPassed: false },
    });
  });
});
