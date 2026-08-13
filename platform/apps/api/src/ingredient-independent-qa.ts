import { ingredientStoreCaptureResultSchema, ingredientStoreQaCompleteSchema } from "@thriftycrew/contracts";
import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";
import type { z } from "zod";
import type { WorkerEnv } from "./env";
import { sealAggregateIfTerminal } from "./ingredient-pricing-v2";
import type { IngredientAggregate } from "./ingredient-state-machine";

type CaptureResult = z.infer<typeof ingredientStoreCaptureResultSchema>;
type QaComplete = z.infer<typeof ingredientStoreQaCompleteSchema>;

async function verifyPointer(bucket: R2Bucket, pointer: { objectKey: string; sha256: string; byteLength: number }): Promise<void> {
  const object = await bucket.get(pointer.objectKey);
  if (!object) throw new Error("ingredient evidence object is absent");
  const bytes = new Uint8Array(await object.arrayBuffer());
  if (bytes.byteLength !== pointer.byteLength || await digestHex(bytes) !== pointer.sha256) throw new Error("ingredient evidence failed SHA-256 or length verification");
}

export async function completeIngredientStoreCapture(env: Pick<WorkerEnv, "DB" | "EVIDENCE">, checkId: string, inputValue: unknown) {
  const input: CaptureResult = ingredientStoreCaptureResultSchema.parse(inputValue);
  const row = await env.DB.prepare(`SELECT check_row.store_location_id, check_row.lease_owner, check_row.lease_generation,
      check_row.lease_lane, check_row.query_plan_hash, policy.price_mode
      FROM ingredient_store_checks check_row JOIN store_pricing_policies policy ON policy.store_location_id = check_row.store_location_id
      WHERE check_row.id = ?1 AND check_row.state = 'leased'`).bind(checkId).first<Record<string, unknown>>();
  if (!row || row.lease_owner !== input.owner || Number(row.lease_generation) !== input.leaseGeneration || row.lease_lane !== "targeted_refresh") {
    throw new Error("capture completion rejected by lease fence or lane boundary");
  }
  if (input.result.storeLocationId !== row.store_location_id || input.queryPlanHash !== row.query_plan_hash) throw new Error("capture result identity mismatch");
  if (!input.result.searchComplete || !input.result.locationVerified || !input.result.priceModeVerified || input.result.fulfillmentMode !== row.price_mode) {
    throw new Error("capture result lacks complete location/mode proof");
  }
  if (new Set(input.coverage.map((item) => item.normalizedQuery)).size !== input.coverage.length) throw new Error("capture coverage contains duplicate queries");
  await verifyPointer(env.EVIDENCE, input.evidence);
  const evidenceId = await deterministicId("ingredient-producer-evidence", checkId, input.evidence.sha256);
  const statements: D1PreparedStatement[] = [env.DB.prepare(`INSERT INTO ingredient_evidence_refs
    (id, store_check_id, kind, object_key, sha256, byte_length, content_type, observed_at, source_url)
    VALUES (?1, ?2, 'query', ?3, ?4, ?5, ?6, ?7, ?8) ON CONFLICT(store_check_id, kind, sha256) DO NOTHING`)
    .bind(evidenceId, checkId, input.evidence.objectKey, input.evidence.sha256, input.evidence.byteLength,
      input.evidence.contentType, input.evidence.observedAt, input.evidence.sourceUrl)];
  for (const coverage of input.coverage) {
    const coverageId = await deterministicId("ingredient-query-coverage", checkId, coverage.normalizedQuery, input.evidence.sha256);
    statements.push(env.DB.prepare(`INSERT INTO ingredient_query_coverage
      (id, store_check_id, normalized_query, store_location_id, price_mode, scope_root_id, page_count, result_count,
       complete, termination_reason, result_set_hash, location_verified, price_mode_verified, completed_at, expires_at,
       evidence_hash, retailer_result_total, end_of_results_proven, pagination_hash, query_plan_hash, producer_version)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1, 'end_of_results', ?9, 1, 1, ?10, ?11, ?12, ?13, 1, ?14, ?15, ?16)
      ON CONFLICT(store_check_id, normalized_query, scope_root_id) DO NOTHING`)
      .bind(coverageId, checkId, coverage.normalizedQuery, row.store_location_id, row.price_mode,
        `targeted:${input.evidence.sha256}`, coverage.pageCount, coverage.resultCount, input.candidateSetHash,
        coverage.completedAt, coverage.expiresAt, coverage.evidenceHash, coverage.retailerResultTotal,
        coverage.paginationHash, input.queryPlanHash, input.producerVersion));
  }
  statements.push(env.DB.prepare(`UPDATE ingredient_store_checks SET state = 'qa_pending', operational_state = 'qa_queued',
    capture_result_json = ?4, candidate_set_hash = ?5, producer_evidence_id = ?6, producer_version = ?7,
    capture_completed_at = CURRENT_TIMESTAMP, evidence_generation = evidence_generation + 1,
    lease_owner = NULL, lease_expires_at = NULL, heartbeat_at = NULL, lease_lane = NULL,
    last_error = NULL, last_progress_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
    WHERE id = ?1 AND state = 'leased' AND lease_owner = ?2 AND lease_generation = ?3`)
    .bind(checkId, input.owner, input.leaseGeneration, stableJson(input.result), input.candidateSetHash, evidenceId, input.producerVersion));
  const results = await env.DB.batch(statements);
  if ((results.at(-1)?.meta.changes ?? 0) !== 1) throw new Error("capture completion lost its lease fence");
  return { checkId, state: "qa_queued" as const };
}

export async function completeIngredientStoreQa(env: Pick<WorkerEnv, "DB" | "EVIDENCE">, checkId: string, inputValue: unknown): Promise<IngredientAggregate> {
  const input: QaComplete = ingredientStoreQaCompleteSchema.parse(inputValue);
  const row = await env.DB.prepare(`SELECT pricing_job_id, lease_owner, lease_generation, lease_lane,
      capture_result_json, candidate_set_hash, producer_evidence_id FROM ingredient_store_checks
      WHERE id = ?1 AND state = 'leased'`).bind(checkId).first<Record<string, unknown>>();
  if (!row || row.lease_owner !== input.owner || Number(row.lease_generation) !== input.leaseGeneration || row.lease_lane !== "qa") {
    throw new Error("QA completion rejected by lease fence or lane boundary");
  }
  if (!row.capture_result_json || !row.producer_evidence_id) throw new Error("QA has no frozen producer evidence");
  const result = JSON.parse(String(row.capture_result_json)) as { outcome: string; searchComplete: boolean; locationVerified: boolean; priceModeVerified: boolean; qualifyingProductsExamined: number };
  if (input.verdict !== "ambiguous" && input.verdict !== result.outcome) throw new Error("QA verdict disagrees with captured outcome");
  if (input.verdict !== "ambiguous" && (!result.searchComplete || !result.locationVerified || !result.priceModeVerified)) throw new Error("QA cannot verify incomplete capture");
  if (input.verdict === "priced" && result.qualifyingProductsExamined < 1) throw new Error("priced QA requires a qualifying candidate");
  if (input.verdict === "not_found" && result.qualifyingProductsExamined !== 0) throw new Error("not-found QA requires zero qualifying candidates");
  await verifyPointer(env.EVIDENCE, input.verifierEvidence);
  const producer = await env.DB.prepare("SELECT sha256 FROM ingredient_evidence_refs WHERE id = ?1").bind(row.producer_evidence_id).first<{ sha256: string }>();
  if (!producer || producer.sha256 === input.verifierEvidence.sha256) throw new Error("producer and verifier evidence must be distinct");
  const verifierEvidenceId = await deterministicId("ingredient-verifier-evidence", checkId, input.verifierEvidence.sha256);
  const qaInputHash = await digestHex(stableJson({ result, candidateSetHash: row.candidate_set_hash, producer: producer.sha256, verifier: input.verifierEvidence.sha256 }));
  const qaOutputHash = await digestHex(stableJson({ verdict: input.verdict, findings: input.findings, validators: input.validatorVersions, verifierVersion: input.verifierVersion }));
  const qaId = await deterministicId("ingredient-independent-qa", checkId, qaInputHash, qaOutputHash);
  const terminal = input.verdict === "priced" ? "qa_verified_priced" : input.verdict === "not_found" ? "qa_verified_not_found" : "ambiguous";
  const statements = [
    env.DB.prepare(`INSERT INTO ingredient_evidence_refs (id, store_check_id, kind, object_key, sha256, byte_length, content_type, observed_at, source_url)
      VALUES (?1, ?2, 'qa_bundle', ?3, ?4, ?5, ?6, ?7, ?8) ON CONFLICT(store_check_id, kind, sha256) DO NOTHING`)
      .bind(verifierEvidenceId, checkId, input.verifierEvidence.objectKey, input.verifierEvidence.sha256, input.verifierEvidence.byteLength,
        input.verifierEvidence.contentType, input.verifierEvidence.observedAt, input.verifierEvidence.sourceUrl),
    env.DB.prepare(`INSERT INTO ingredient_qa_attestations (id, store_check_id, input_hash, validator_versions_json, verdict, findings_json, output_hash)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT(store_check_id, input_hash, output_hash) DO NOTHING`)
      .bind(qaId, checkId, qaInputHash, stableJson(input.validatorVersions), input.verdict, stableJson(input.findings), qaOutputHash),
    env.DB.prepare(`UPDATE ingredient_store_checks SET state = ?4, operational_state = ?4, terminal_outcome = ?5,
      qa_attestation_id = ?6, verifier_evidence_id = ?7, verifier_version = ?8, qa_generation = qa_generation + 1,
      qa_completed_at = CURRENT_TIMESTAMP, lease_owner = NULL, lease_expires_at = NULL, heartbeat_at = NULL,
      lease_lane = NULL, last_error = ?9, last_progress_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND state = 'leased' AND lease_owner = ?2 AND lease_generation = ?3`)
      .bind(checkId, input.owner, input.leaseGeneration, terminal, input.verdict === "ambiguous" ? null : input.verdict,
        qaId, verifierEvidenceId, input.verifierVersion, input.verdict === "ambiguous" ? input.findings.join("; ") : null),
  ];
  const results = await env.DB.batch(statements);
  if ((results.at(-1)?.meta.changes ?? 0) !== 1) throw new Error("QA completion lost its lease fence");
  return sealAggregateIfTerminal(env, String(row.pricing_job_id));
}
