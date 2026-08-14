import { ingredientCaptureChallengeOpenSchema, ingredientCaptureChallengeResolveSchema } from "@thriftycrew/contracts";
import type { z } from "zod";

type Open = z.infer<typeof ingredientCaptureChallengeOpenSchema>;
type Resolve = z.infer<typeof ingredientCaptureChallengeResolveSchema>;

export async function openIngredientChallenge(db: D1Database, checkId: string, value: unknown) {
  const input: Open = ingredientCaptureChallengeOpenSchema.parse(value);
  const check = await db.prepare(`SELECT store_location_id, entity_id, lease_owner, lease_generation, lease_lane
    FROM ingredient_store_checks check_row JOIN ingredient_pricing_jobs job ON job.id = check_row.pricing_job_id
    WHERE check_row.id = ?1 AND check_row.state = 'leased'`).bind(checkId).first<Record<string, unknown>>();
  if (!check || check.lease_owner !== input.owner || Number(check.lease_generation) !== input.leaseGeneration || check.lease_lane !== "targeted_refresh") {
    throw new Error("challenge open rejected by capture lease fence");
  }
  await db.batch([
    db.prepare(`INSERT INTO ingredient_capture_challenges
      (id, store_check_id, store_location_id, ingredient_entity_id, normalized_query, session_id, tab_ownership_id,
       reason, pre_canary_evidence_hash, opened_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, CURRENT_TIMESTAMP)
      ON CONFLICT(id) DO NOTHING`).bind(input.challengeId, checkId, check.store_location_id, check.entity_id,
        input.normalizedQuery, input.sessionId, input.tabOwnershipId, input.reason, input.preCanaryEvidenceHash),
    db.prepare(`UPDATE ingredient_store_checks SET state = 'blocked_challenge', operational_state = 'challenge_blocked',
      challenge_id = ?4, last_error = ?5, lease_owner = NULL, lease_expires_at = NULL, lease_lane = NULL,
      last_progress_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND state = 'leased' AND lease_owner = ?2 AND lease_generation = ?3`)
      .bind(checkId, input.owner, input.leaseGeneration, input.challengeId, input.reason),
  ]);
  return { checkId, challengeId: input.challengeId, state: "challenge_blocked" };
}

export async function acknowledgeIngredientChallenge(db: D1Database, challengeId: string) {
  const update = await db.prepare(`UPDATE ingredient_capture_challenges SET acknowledged_at = COALESCE(acknowledged_at, CURRENT_TIMESTAMP)
    WHERE id = ?1 AND resolved_at IS NULL AND abandoned_at IS NULL`).bind(challengeId).run();
  if ((update.meta.changes ?? 0) !== 1) throw new Error("open ingredient challenge not found");
  return { challengeId, acknowledged: true };
}

export async function resolveIngredientChallenge(db: D1Database, challengeId: string, value: unknown) {
  const input: Resolve = ingredientCaptureChallengeResolveSchema.parse(value);
  const challenge = await db.prepare("SELECT store_check_id, acknowledged_at FROM ingredient_capture_challenges WHERE id = ?1 AND resolved_at IS NULL AND abandoned_at IS NULL")
    .bind(challengeId).first<{ store_check_id: string; acknowledged_at: string | null }>();
  if (!challenge || !challenge.acknowledged_at) throw new Error("challenge must be acknowledged by the Done callback before resolution");
  if (!input.canaryPassed) return { challengeId, resolved: false, state: "challenge_blocked" };
  await db.batch([
    db.prepare(`UPDATE ingredient_capture_challenges SET post_canary_evidence_hash = ?2,
      canary_passed_at = CURRENT_TIMESTAMP, resolved_at = CURRENT_TIMESTAMP WHERE id = ?1 AND resolved_at IS NULL`)
      .bind(challengeId, input.postCanaryEvidenceHash),
    db.prepare(`UPDATE ingredient_store_checks SET state = 'targeted_refresh', operational_state = 'capture_queued',
      challenge_id = NULL, next_attempt_at = CURRENT_TIMESTAMP, last_error = NULL, last_progress_at = CURRENT_TIMESTAMP,
      updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND state = 'blocked_challenge' AND challenge_id = ?2`)
      .bind(challenge.store_check_id, challengeId),
  ]);
  return { challengeId, resolved: true, state: "capture_queued" };
}
