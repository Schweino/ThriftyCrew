import { describe, expect, it } from "vitest";
import { publicationCandidates } from "./ingredient-publication-snapshot";

const base = {
  commodity_id: "new-ingredient", store_location_id: "walmart", normalized_name: "same item 8 oz",
  observation_id: "targeted", per_unit_micros: 100, captured_at: "2026-08-14T00:00:00Z",
  valid_to: null, coverage_mode: "targeted" as const, captured_to: "2026-08-14T00:00:00Z",
  batch_id: "targeted-batch", normalized_basis_unit: "oz", known_wrong: 0,
};

describe("ingredient publication snapshot", () => {
  it("keeps targeted evidence and an equivalent complete-catalog candidate", () => {
    const candidates = [base, { ...base, observation_id: "complete", coverage_mode: "full" as const, batch_id: "full-batch" }];
    expect(publicationCandidates(candidates, new Set(["new-ingredient"]), new Set(["targeted-batch"]))
      .map((candidate) => candidate.observation_id)).toEqual(["targeted", "complete"]);
  });

  it("excludes unrelated complete products and all unrelated thin candidates for the new commodity", () => {
    const candidates = [base,
      { ...base, observation_id: "other-name", normalized_name: "different item", coverage_mode: "full" as const, batch_id: "full-batch" },
      { ...base, observation_id: "other-store", store_location_id: "aldi", coverage_mode: "full" as const, batch_id: "full-batch" },
      { ...base, observation_id: "partial", coverage_mode: "partial" as const, batch_id: "partial-batch" },
    ];
    expect(publicationCandidates(candidates, new Set(["new-ingredient"]), new Set(["targeted-batch"]))
      .map((candidate) => candidate.observation_id)).toEqual(["targeted"]);
  });
});
