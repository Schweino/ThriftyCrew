export interface InactiveDecisionReconciliation {
  activeConfigurationId: string | null;
  effectiveBatches: number;
  missingActiveMatches: number;
  superseded: number;
  ready: boolean;
}

export async function reconcileInactiveConfigurationDecisions(
  db: D1Database,
  observedAt = new Date().toISOString(),
): Promise<InactiveDecisionReconciliation> {
  const active = await db.prepare(
    "SELECT id FROM configuration_versions WHERE active = 1",
  ).first<{ id: string }>();
  if (!active) return { activeConfigurationId: null, effectiveBatches: 0, missingActiveMatches: 0, superseded: 0, ready: false };

  const coverage = await db.prepare(
    `WITH ranked AS (
       SELECT batch.id,
              ROW_NUMBER() OVER (
                PARTITION BY batch.source_id
                ORDER BY batch.captured_to DESC, batch.promoted_at DESC, batch.id DESC
              ) AS ordinal
         FROM capture_batches batch
        WHERE batch.status IN ('promoted','superseded')
          AND (batch.valid_from IS NULL OR batch.valid_from <= ?1)
          AND (batch.valid_to IS NULL OR batch.valid_to > ?1)
     ), effective AS (
       SELECT id FROM ranked WHERE ordinal = 1
     )
     SELECT COUNT(*) AS effective_batches,
            COALESCE(SUM(CASE WHEN EXISTS (
              SELECT 1 FROM match_runs run
               WHERE run.batch_id = effective.id
                 AND run.configuration_id = ?2
                 AND run.status = 'passed'
                 AND run.matched_count = (
                   SELECT COUNT(DISTINCT CASE WHEN decision.product_id IS NOT NULL THEN product.id END)
                     FROM capture_batch_observations member
                     JOIN observations observation ON observation.id = member.observation_id
                     JOIN product_versions version ON version.id = observation.product_version_id
                     JOIN products product ON product.id = version.product_id
                     LEFT JOIN match_decisions decision ON decision.product_id = product.id
                      AND decision.configuration_id = ?2 AND decision.superseded_at IS NULL
                    WHERE member.batch_id = effective.id
                 )
            ) THEN 0 ELSE 1 END), 0) AS missing_active_matches
       FROM effective`,
  ).bind(observedAt, active.id).first<{ effective_batches: number; missing_active_matches: number }>();
  const effectiveBatches = Number(coverage?.effective_batches ?? 0);
  const missingActiveMatches = Number(coverage?.missing_active_matches ?? 0);
  if (effectiveBatches === 0 || missingActiveMatches !== 0) {
    return { activeConfigurationId: active.id, effectiveBatches, missingActiveMatches, superseded: 0, ready: false };
  }

  const updated = await db.prepare(
    `WITH ranked AS (
       SELECT batch.id,
              ROW_NUMBER() OVER (
                PARTITION BY batch.source_id
                ORDER BY batch.captured_to DESC, batch.promoted_at DESC, batch.id DESC
              ) AS ordinal
         FROM capture_batches batch
        WHERE batch.status IN ('promoted','superseded')
          AND (batch.valid_from IS NULL OR batch.valid_from <= ?1)
          AND (batch.valid_to IS NULL OR batch.valid_to > ?1)
     ), effective AS (
       SELECT id FROM ranked WHERE ordinal = 1
     )
     UPDATE match_decisions
        SET superseded_at = CURRENT_TIMESTAMP
      WHERE superseded_at IS NULL
        AND configuration_id <> ?2
        AND ?2 = (SELECT id FROM configuration_versions WHERE active = 1)
        AND EXISTS (SELECT 1 FROM effective)
        AND NOT EXISTS (
          SELECT 1 FROM effective
           WHERE NOT EXISTS (
             SELECT 1 FROM match_runs run
              WHERE run.batch_id = effective.id
                AND run.configuration_id = ?2
                AND run.status = 'passed'
                AND run.matched_count = (
                  SELECT COUNT(DISTINCT CASE WHEN decision.product_id IS NOT NULL THEN product.id END)
                    FROM capture_batch_observations member
                    JOIN observations observation ON observation.id = member.observation_id
                    JOIN product_versions version ON version.id = observation.product_version_id
                    JOIN products product ON product.id = version.product_id
                    LEFT JOIN match_decisions decision ON decision.product_id = product.id
                     AND decision.configuration_id = ?2 AND decision.superseded_at IS NULL
                   WHERE member.batch_id = effective.id
                )
           )
        )`,
  ).bind(observedAt, active.id).run();
  return {
    activeConfigurationId: active.id,
    effectiveBatches,
    missingActiveMatches,
    superseded: updated.meta.changes ?? 0,
    ready: true,
  };
}
