import type { WorkerEnv } from "./env";

export interface CaptureUploadAttempt {
  id: string;
  batch_id: string;
  requested_by: string;
  evidence_id: string;
  attempt_number: number;
  object_key: string;
  kind: "screenshot" | "flyer_page" | "raw_payload" | "manifest";
  content_type: string;
  expected_sha256: string;
  expected_md5: string;
  expected_bytes: number;
  status: "issued" | "finalized" | "expired" | "rejected" | "cleaned";
  expires_at: string;
}

export interface CaptureUploadAttemptInput {
  batchId: string;
  requestedBy: string;
  evidenceId: string;
  kind: CaptureUploadAttempt["kind"];
  contentType: string;
  sha256: string;
  contentMd5: string;
  byteLength: number;
}

function sameEvidence(attempt: CaptureUploadAttempt, input: CaptureUploadAttemptInput): boolean {
  return attempt.kind === input.kind
    && attempt.content_type === input.contentType
    && attempt.expected_sha256 === input.sha256
    && attempt.expected_md5 === input.contentMd5
    && attempt.expected_bytes === input.byteLength;
}

export function reusableCaptureUploadAttempt(attempt: CaptureUploadAttempt, now: number): boolean {
  return attempt.status === "issued" && Date.parse(attempt.expires_at) > now + 60_000;
}

async function latestAttempt(env: WorkerEnv, batchId: string, evidenceId: string): Promise<CaptureUploadAttempt | null> {
  return await env.DB.prepare(`
    SELECT id, batch_id, requested_by, evidence_id, attempt_number, object_key, kind, content_type,
           expected_sha256, expected_md5, expected_bytes, status, expires_at
      FROM capture_evidence_upload_attempts
     WHERE batch_id = ?1 AND evidence_id = ?2
     ORDER BY attempt_number DESC LIMIT 1
  `).bind(batchId, evidenceId).first<CaptureUploadAttempt>();
}

export async function issueCaptureUploadAttempt(
  env: WorkerEnv,
  input: CaptureUploadAttemptInput,
  now = Date.now(),
): Promise<CaptureUploadAttempt> {
  let latest = await latestAttempt(env, input.batchId, input.evidenceId);
  if (latest && !sameEvidence(latest, input)) throw new Error("evidence id already has an upload attempt bound to different content");
  if (latest?.status === "finalized") return latest;
  if (latest && reusableCaptureUploadAttempt(latest, now)) return latest;

  if (latest?.status === "issued") {
    await env.DB.prepare(`
      UPDATE capture_evidence_upload_attempts
         SET status = 'expired'
       WHERE id = ?1 AND status = 'issued' AND expires_at <= ?2
    `).bind(latest.id, new Date(now + 60_000).toISOString()).run();
  }

  const attemptNumber = (latest?.attempt_number ?? 0) + 1;
  const uploadSessionId = `upload_${crypto.randomUUID()}`;
  const objectKey = `batches/${input.batchId}/${input.evidenceId}/attempt-${attemptNumber}-${uploadSessionId}`;
  const expiresAt = new Date(now + 15 * 60_000).toISOString();
  await env.DB.prepare(`
    INSERT OR IGNORE INTO capture_evidence_upload_attempts
      (id, batch_id, requested_by, evidence_id, attempt_number, object_key, kind, content_type,
       expected_sha256, expected_md5, expected_bytes, expires_at)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
  `).bind(
    uploadSessionId, input.batchId, input.requestedBy, input.evidenceId, attemptNumber, objectKey,
    input.kind, input.contentType, input.sha256, input.contentMd5, input.byteLength, expiresAt,
  ).run();

  latest = await latestAttempt(env, input.batchId, input.evidenceId);
  if (!latest || latest.attempt_number < attemptNumber || !sameEvidence(latest, input)) {
    throw new Error("direct evidence upload attempt could not be issued safely");
  }
  if (!reusableCaptureUploadAttempt(latest, now)) {
    throw new Error("direct evidence upload attempt raced with another terminal transition; retry issuance");
  }
  return latest;
}

export interface CaptureUploadCleanupResult {
  expired: number;
  selected: number;
  deleted: number;
  failed: Array<{ uploadSessionId: string; objectKey: string; error: string }>;
}

export async function cleanupCaptureUploadAttempts(
  env: WorkerEnv,
  scheduledTime: number,
  limit = 25,
): Promise<CaptureUploadCleanupResult> {
  const now = new Date(scheduledTime).toISOString();
  const graceCutoff = new Date(scheduledTime - 60 * 60_000).toISOString();
  const expiredAttempts = await env.DB.prepare(`
    UPDATE capture_evidence_upload_attempts
       SET status = 'expired'
     WHERE status = 'issued' AND expires_at <= ?1
  `).bind(now).run();
  const expiredLegacy = await env.DB.prepare(`
    UPDATE capture_evidence_upload_sessions
       SET status = 'expired'
     WHERE status = 'issued' AND expires_at <= ?1
  `).bind(now).run();
  const boundedLimit = Math.min(100, Math.max(1, limit));
  const attempts = await env.DB.prepare(`
    SELECT attempt.id AS upload_session_id, attempt.object_key
      FROM capture_evidence_upload_attempts attempt
     WHERE attempt.status IN ('expired','rejected')
       AND attempt.cleaned_at IS NULL
       AND attempt.expires_at <= ?1
       AND NOT EXISTS (
         SELECT 1 FROM evidence_objects evidence WHERE evidence.object_key = attempt.object_key
       )
     ORDER BY attempt.expires_at, attempt.id
     LIMIT ?2
  `).bind(graceCutoff, boundedLimit).all<{ upload_session_id: string; object_key: string }>();
  const legacyLimit = boundedLimit - attempts.results.length;
  const legacy = legacyLimit > 0 ? await env.DB.prepare(`
    SELECT session.id AS upload_session_id, session.object_key
      FROM capture_evidence_upload_sessions session
     WHERE session.status IN ('expired','rejected')
       AND session.cleaned_at IS NULL
       AND session.expires_at <= ?1
       AND NOT EXISTS (
         SELECT 1 FROM evidence_objects evidence WHERE evidence.object_key = session.object_key
       )
     ORDER BY session.expires_at, session.id
     LIMIT ?2
  `).bind(graceCutoff, legacyLimit).all<{ upload_session_id: string; object_key: string }>() : { results: [] };
  const candidates = [
    ...attempts.results.map((candidate) => ({ ...candidate, table: "capture_evidence_upload_attempts" as const })),
    ...legacy.results.map((candidate) => ({ ...candidate, table: "capture_evidence_upload_sessions" as const })),
  ];
  let deleted = 0;
  const failed: CaptureUploadCleanupResult["failed"] = [];
  for (const candidate of candidates) {
    try {
      await env.EVIDENCE.delete(candidate.object_key);
      const marked = await env.DB.prepare(candidate.table === "capture_evidence_upload_attempts" ? `
        UPDATE capture_evidence_upload_attempts
           SET status = 'cleaned', cleaned_at = ?2
         WHERE id = ?1 AND status IN ('expired','rejected') AND cleaned_at IS NULL
      ` : `
        UPDATE capture_evidence_upload_sessions
           SET cleaned_at = ?2
         WHERE id = ?1 AND status IN ('expired','rejected') AND cleaned_at IS NULL
      `).bind(candidate.upload_session_id, now).run();
      if ((marked.meta.changes ?? 0) === 1) deleted += 1;
    } catch (error) {
      failed.push({
        uploadSessionId: candidate.upload_session_id,
        objectKey: candidate.object_key,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
  return {
    expired: (expiredAttempts.meta.changes ?? 0) + (expiredLegacy.meta.changes ?? 0),
    selected: candidates.length,
    deleted,
    failed,
  };
}
