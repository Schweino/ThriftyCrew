import { describe, expect, it } from "vitest";
import { buildHistoricalTriageArchive } from "./triage-compaction";

describe("historical triage archive", () => {
  it("groups immutable result, finding, and triage evidence without losing status", () => {
    const base = {
      result_id: "result", guard_id: "release-arithmetic", release_id: "old-release", guard_status: "fail",
      eligible_count: 2, examined_count: 2, finding_count: 2, guard_detail_json: "{}",
      guard_created_at: "2026-08-01T00:00:00Z", release_state: "published", release_published_at: "2026-08-01T00:00:00Z",
      triage_severity: "hard", triage_status: "open", triage_title: "title", triage_evidence_json: "{}",
      triage_plan_ref: null, triage_resolution_json: "{}", triage_created_at: "2026-08-01T00:00:00Z",
      triage_updated_at: "2026-08-01T00:00:00Z", triage_resolved_at: null,
    };
    const archive = buildHistoricalTriageArchive("current", "2026-08-12T00:00:00Z", [
      { ...base, finding_id: "finding-a", finding_key: "a", finding_message: "A", finding_evidence_json: "{\"a\":1}", triage_id: "triage-a" },
      { ...base, finding_id: "finding-b", finding_key: "b", finding_message: "B", finding_evidence_json: "{\"b\":1}", triage_id: null,
        triage_severity: null, triage_status: null, triage_title: null, triage_evidence_json: null, triage_plan_ref: null,
        triage_resolution_json: null, triage_created_at: null, triage_updated_at: null, triage_resolved_at: null },
    ]);
    expect(archive.results).toHaveLength(1);
    expect(archive.results[0]?.findings).toHaveLength(2);
    expect(archive.results[0]?.findings[0]?.triage).toMatchObject({ id: "triage-a", status: "open" });
    expect(archive.results[0]?.findings[1]?.triage).toBeNull();
  });
});
