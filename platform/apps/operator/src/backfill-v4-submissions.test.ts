import { describe, expect, it } from "vitest";
import { buildBackfillSubmissions } from "./backfill-v4-submissions";

const future = "2026-08-14T22:30:00.000Z";
const claim = { workItems: [
  { id: "work_b", agent_id: "omaha-price-producer-walmart", lease_owner: "v4-backfill-browser-walmart", lease_generation: 2,
    lease_expires_at: future, input_json: JSON.stringify({ queryTerms: ["Bell Peppers"] }) },
  { id: "work_a", agent_id: "omaha-price-producer-walmart", lease_owner: "v4-backfill-browser-walmart", lease_generation: 2,
    lease_expires_at: future, input_json: JSON.stringify({ queryTerms: ["Apples"] }) },
] };
const chunk = { version: 2, phase: "discovery", store: "walmart", canary: { observedAt: "2026-08-14T21:31:00.000Z" },
  terms: [{ query: "Apples" }, { query: "Bell Peppers" }], rows: [{ term: "Bell Peppers", id: "b" }, { term: "Apples", id: "a" }] };

describe("V4 backfill submission mapper", () => {
  it("deterministically emits one exactly sliced lease-fenced wrapper per work item", () => {
    const result = buildBackfillSubmissions({ role: "producer", claim, chunk, generationPrefix: "producer-gen",
      sessionPrefix: "producer-session", now: new Date("2026-08-14T21:32:00.000Z") });
    expect(result.map((row) => row.workItemId)).toEqual(["work_a", "work_b"]);
    expect(result[0]).toMatchObject({ owner: "v4-backfill-browser-walmart", leaseGeneration: 2,
      generationId: "producer-gen:work_a", sessionId: "producer-session:work_a",
      document: { terms: [{ query: "Apples" }], rows: [{ term: "Apples", id: "a" }] } });
  });

  it("rejects expired leases, missing locked queries, extra terms, and mixed roles", () => {
    expect(() => buildBackfillSubmissions({ role: "producer", claim, chunk, generationPrefix: "g", sessionPrefix: "s",
      now: new Date("2026-08-14T23:00:00.000Z") })).toThrow("expired");
    expect(() => buildBackfillSubmissions({ role: "producer", claim, chunk: { ...chunk, terms: chunk.terms.slice(0, 1) },
      generationPrefix: "g", sessionPrefix: "s", now: new Date("2026-08-14T21:32:00.000Z") })).toThrow("omitted locked query");
    expect(() => buildBackfillSubmissions({ role: "producer", claim: { workItems: claim.workItems.slice(0, 1) }, chunk,
      generationPrefix: "g", sessionPrefix: "s", now: new Date("2026-08-14T21:32:00.000Z") })).toThrow("outside the claim");
    const verifier = { workItems: [{ ...claim.workItems[0], agent_id: "omaha-price-verifier-walmart" }] };
    expect(() => buildBackfillSubmissions({ role: "producer", claim: verifier, chunk: { ...chunk, terms: [chunk.terms[1]], rows: [chunk.rows[0]] },
      generationPrefix: "g", sessionPrefix: "s", now: new Date("2026-08-14T21:32:00.000Z") })).toThrow("mixes non-producer");
  });
});

