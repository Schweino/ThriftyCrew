import { pipelineOutboxAcknowledgeSchema, pipelineOutboxClaimSchema, pipelineOutboxNackSchema } from "@thriftycrew/contracts";
import type { z } from "zod";

type Claim = z.infer<typeof pipelineOutboxClaimSchema>;
type Acknowledge = z.infer<typeof pipelineOutboxAcknowledgeSchema>;
type Nack = z.infer<typeof pipelineOutboxNackSchema>;

export async function claimPipelineOutbox(db: D1Database, inputValue: unknown): Promise<Record<string, unknown>[]> {
  const input: Claim = pipelineOutboxClaimSchema.parse(inputValue);
  const now = new Date();
  const expiresAt = new Date(now.getTime() + input.leaseSeconds * 1000).toISOString();
  const candidates = await db.prepare(
    `SELECT id FROM pipeline_outbox
      WHERE acknowledged_at IS NULL AND available_at <= ?1
        AND (lease_expires_at IS NULL OR lease_expires_at <= ?1)
      ORDER BY available_at, id LIMIT ?2`,
  ).bind(now.toISOString(), input.limit).all<{ id: number }>();
  const claimed: Record<string, unknown>[] = [];
  for (const candidate of candidates.results) {
    const update = await db.prepare(
      `UPDATE pipeline_outbox SET lease_owner = ?2, lease_generation = lease_generation + 1,
          lease_expires_at = ?3, delivered_at = COALESCE(delivered_at, ?4),
          attempt_count = attempt_count + 1, last_delivery_error = NULL
        WHERE id = ?1 AND acknowledged_at IS NULL
          AND (lease_expires_at IS NULL OR lease_expires_at <= ?4)`,
    ).bind(candidate.id, input.owner, expiresAt, now.toISOString()).run();
    if ((update.meta.changes ?? 0) !== 1) continue;
    const row = await db.prepare(
      `SELECT id, topic, aggregate_kind, aggregate_id, dedupe_key, payload_json,
              payload_hash, lease_generation, created_at
         FROM pipeline_outbox WHERE id = ?1`,
    ).bind(candidate.id).first<Record<string, unknown>>();
    if (row) claimed.push({ ...row, payload: JSON.parse(String(row.payload_json)), payload_json: undefined });
  }
  return claimed;
}

export async function acknowledgePipelineOutbox(db: D1Database, id: number, inputValue: unknown): Promise<void> {
  const input: Acknowledge = pipelineOutboxAcknowledgeSchema.parse(inputValue);
  const update = await db.prepare(
    `UPDATE pipeline_outbox SET acknowledged_at = CURRENT_TIMESTAMP, lease_owner = NULL,
        lease_expires_at = NULL, last_delivery_error = NULL
      WHERE id = ?1 AND acknowledged_at IS NULL AND lease_owner = ?2 AND lease_generation = ?3`,
  ).bind(id, input.owner, input.leaseGeneration).run();
  if ((update.meta.changes ?? 0) !== 1) throw new Error("outbox acknowledgement rejected by lease fence");
}

export async function nackPipelineOutbox(db: D1Database, id: number, inputValue: unknown): Promise<void> {
  const input: Nack = pipelineOutboxNackSchema.parse(inputValue);
  const update = await db.prepare(
    `UPDATE pipeline_outbox SET available_at = ?4, lease_owner = NULL, lease_expires_at = NULL,
        last_delivery_error = ?5, last_error = ?5
      WHERE id = ?1 AND acknowledged_at IS NULL AND lease_owner = ?2 AND lease_generation = ?3`,
  ).bind(id, input.owner, input.leaseGeneration, input.retryAt, input.reason).run();
  if ((update.meta.changes ?? 0) !== 1) throw new Error("outbox nack rejected by lease fence");
}
