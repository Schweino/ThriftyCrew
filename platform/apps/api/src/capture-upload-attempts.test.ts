import { describe, expect, it, vi } from "vitest";
import { cleanupCaptureUploadAttempts, issueCaptureUploadAttempt, reusableCaptureUploadAttempt, type CaptureUploadAttempt } from "./capture-upload-attempts";
import type { WorkerEnv } from "./env";

const input = {
  batchId: "batch-1",
  requestedBy: "capture-agent",
  evidenceId: "evidence-1",
  kind: "manifest" as const,
  contentType: "application/json",
  sha256: "a".repeat(64),
  contentMd5: "1B2M2Y8AsgTpgAmY7PhCfg==",
  byteLength: 123,
};

function attemptDb() {
  const attempts: CaptureUploadAttempt[] = [];
  return {
    attempts,
    prepare(sql: string) {
      return {
        bind: (...values: unknown[]) => ({
          first: async () => attempts
            .filter((row) => row.batch_id === values[0] && row.evidence_id === values[1])
            .sort((left, right) => right.attempt_number - left.attempt_number)[0] ?? null,
          run: async () => {
            if (sql.includes("SET status = 'expired'")) {
              const row = attempts.find((candidate) => candidate.id === values[0]);
              if (row?.status === "issued" && Date.parse(row.expires_at) <= Date.parse(String(values[1]))) row.status = "expired";
              return { meta: { changes: row?.status === "expired" ? 1 : 0 } };
            }
            if (sql.includes("INSERT OR IGNORE")) {
              if (!attempts.some((row) => row.batch_id === values[1] && row.evidence_id === values[3] && row.attempt_number === values[4])) {
                attempts.push({
                  id: String(values[0]), batch_id: String(values[1]), requested_by: String(values[2]), evidence_id: String(values[3]),
                  attempt_number: Number(values[4]), object_key: String(values[5]), kind: values[6] as CaptureUploadAttempt["kind"],
                  content_type: String(values[7]), expected_sha256: String(values[8]), expected_md5: String(values[9]),
                  expected_bytes: Number(values[10]), status: "issued", expires_at: String(values[11]),
                });
              }
              return { meta: { changes: 1 } };
            }
            return { meta: { changes: 0 } };
          },
        }),
      };
    },
  };
}

describe("direct capture upload attempts", () => {
  it("reuses a healthy attempt but creates a new immutable object after expiry", async () => {
    const db = attemptDb();
    const env = { DB: db } as unknown as WorkerEnv;
    const startedAt = Date.parse("2026-08-11T12:00:00.000Z");
    const first = await issueCaptureUploadAttempt(env, input, startedAt);
    const retry = await issueCaptureUploadAttempt(env, input, startedAt + 5 * 60_000);
    const renewed = await issueCaptureUploadAttempt(env, input, startedAt + 16 * 60_000);
    expect(retry.id).toBe(first.id);
    expect(renewed.id).not.toBe(first.id);
    expect(renewed.attempt_number).toBe(2);
    expect(renewed.object_key).toContain("/attempt-2-");
    expect(db.attempts[0]?.status).toBe("expired");
  });

  it("will not reuse the final minute of a signed URL", () => {
    expect(reusableCaptureUploadAttempt({ status: "issued", expires_at: "2026-08-11T12:01:00.000Z" } as CaptureUploadAttempt,
      Date.parse("2026-08-11T12:00:00.000Z"))).toBe(false);
  });

  it("deletes only selected exact orphan keys and records cleanup", async () => {
    const remove = vi.fn().mockResolvedValue(undefined);
    const updates: unknown[][] = [];
    const db = {
      prepare(sql: string) {
        return { bind: (...values: unknown[]) => ({
          run: async () => {
            updates.push(values);
            return { meta: { changes: sql.includes("UPDATE capture_evidence_upload_sessions") ? 0 : 1 } };
          },
          all: async () => ({ results: sql.includes("FROM capture_evidence_upload_attempts attempt")
            ? [{ upload_session_id: "upload-1", object_key: "batches/batch-1/evidence-1/attempt-1-upload-1" }]
            : [] }),
        }) };
      },
    };
    const result = await cleanupCaptureUploadAttempts({ DB: db, EVIDENCE: { delete: remove } } as unknown as WorkerEnv,
      Date.parse("2026-08-11T14:00:00.000Z"), 10);
    expect(remove).toHaveBeenCalledWith("batches/batch-1/evidence-1/attempt-1-upload-1");
    expect(result).toMatchObject({ expired: 1, selected: 1, deleted: 1, failed: [] });
    expect(updates.at(-1)?.[0]).toBe("upload-1");
  });
});
