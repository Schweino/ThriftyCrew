import { ingredientStoreCaptureResultSchema, ingredientStoreQaCompleteSchema } from "@thriftycrew/contracts";
import { deterministicId, digestHex, normalizeName, stableJson } from "@thriftycrew/domain";
import type { z } from "zod";
import type { WorkerEnv } from "./env";
import { sealAggregateIfTerminal } from "./ingredient-pricing-v2";
import type { IngredientAggregate } from "./ingredient-state-machine";

type CaptureResult = z.infer<typeof ingredientStoreCaptureResultSchema>;
type QaComplete = z.infer<typeof ingredientStoreQaCompleteSchema>;
type QaReject = { owner: string; leaseGeneration: number; reason: string; validatorVersion: string };

export function hasCompleteLocationModeProof(result: CaptureResult["result"], priceMode: unknown): boolean {
  if (!result.searchComplete || !result.locationVerified || !result.priceModeVerified) return false;
  return result.outcome === "not_found" ? result.fulfillmentMode === null : result.fulfillmentMode === priceMode;
}

export function isCompleteVerificationTerm(item: Record<string, any>): boolean {
  const outcome = String(item.outcome);
  const termination = String(item.retrieval?.termination ?? "");
  return item.retrieval?.hasMoreResults === false && (
    (outcome === "success" && termination === "end-of-results")
    || (outcome === "empty" && ["no-results", "end-of-results"].includes(termination))
  );
}

export async function uploadIngredientEvidence(env: Pick<WorkerEnv, "DB" | "EVIDENCE">, input: { checkId: string; kind: string; sourceUrl: string; observedAt: string; document: unknown }) {
  const check = await env.DB.prepare("SELECT id FROM ingredient_store_checks WHERE id = ?1").bind(input.checkId).first<{ id: string }>();
  if (!check) throw new Error("ingredient evidence check does not exist");
  const body = stableJson({ schema: "tc-ingredient-evidence-v3", checkId: input.checkId, kind: input.kind,
    sourceUrl: input.sourceUrl, observedAt: input.observedAt, document: input.document });
  const bytes = new TextEncoder().encode(body);
  if (bytes.byteLength < 2 || bytes.byteLength > 1_000_000) throw new Error("ingredient evidence must be between 2 bytes and 1 MB");
  const sha256 = await digestHex(bytes);
  const objectKey = `ingredient-store-evidence/${input.checkId}/${input.kind}/${sha256}.json`;
  await env.EVIDENCE.put(objectKey, bytes, { httpMetadata: { contentType: "application/json; charset=utf-8" },
    customMetadata: { sha256, kind: input.kind, checkId: input.checkId } });
  await verifyPointer(env.EVIDENCE, { objectKey, sha256, byteLength: bytes.byteLength });
  return { objectKey, sha256, byteLength: bytes.byteLength, contentType: "application/json; charset=utf-8",
    sourceUrl: input.sourceUrl, observedAt: input.observedAt };
}

async function verifyPointer(bucket: R2Bucket, pointer: { objectKey: string; sha256: string; byteLength: number }): Promise<void> {
  const object = await bucket.get(pointer.objectKey);
  if (!object) throw new Error("ingredient evidence object is absent");
  const bytes = new Uint8Array(await object.arrayBuffer());
  if (bytes.byteLength !== pointer.byteLength || await digestHex(bytes) !== pointer.sha256) throw new Error("ingredient evidence failed SHA-256 or length verification");
}

async function readEvidenceEnvelope(bucket: R2Bucket, pointer: { objectKey: string; sha256: string; byteLength: number }) {
  const object = await bucket.get(pointer.objectKey);
  if (!object) throw new Error("ingredient evidence object is absent");
  const bytes = new Uint8Array(await object.arrayBuffer());
  if (bytes.byteLength !== pointer.byteLength || await digestHex(bytes) !== pointer.sha256) throw new Error("ingredient evidence failed SHA-256 or length verification");
  const parsed = JSON.parse(new TextDecoder().decode(bytes)) as Record<string, unknown>;
  if (parsed.schema !== "tc-ingredient-evidence-v3" || typeof parsed.document !== "object" || !parsed.document) throw new Error("ingredient evidence envelope is invalid");
  return parsed as { checkId: string; kind: string; sourceUrl: string; observedAt: string; document: Record<string, any> };
}

export function lockedQueryCoverageTerms(canonicalTerm: string, aliases: string[]): string[] {
  return [...new Set([canonicalTerm, ...aliases].map(normalizeName).filter(Boolean))].sort();
}

export async function completeIngredientStoreCapture(env: Pick<WorkerEnv, "DB" | "EVIDENCE">, checkId: string, inputValue: unknown) {
  const input: CaptureResult = ingredientStoreCaptureResultSchema.parse(inputValue);
  const row = await env.DB.prepare(`SELECT check_row.store_location_id, check_row.lease_owner, check_row.lease_generation,
      check_row.lease_lane, check_row.query_plan_hash, policy.price_mode, plan.canonical_term, plan.aliases_json
      FROM ingredient_store_checks check_row JOIN store_pricing_policies policy ON policy.store_location_id = check_row.store_location_id
      JOIN ingredient_query_plans plan ON plan.id = check_row.query_plan_id
      WHERE check_row.id = ?1 AND check_row.state = 'leased'`).bind(checkId).first<Record<string, unknown>>();
  if (!row || row.lease_owner !== input.owner || Number(row.lease_generation) !== input.leaseGeneration || row.lease_lane !== "targeted_refresh") {
    throw new Error("capture completion rejected by lease fence or lane boundary");
  }
  if (input.result.storeLocationId !== row.store_location_id || input.queryPlanHash !== row.query_plan_hash) throw new Error("capture result identity mismatch");
  if (!hasCompleteLocationModeProof(input.result, row.price_mode)) {
    throw new Error("capture result lacks complete location/mode proof");
  }
  if (new Set(input.coverage.map((item) => item.normalizedQuery)).size !== input.coverage.length) throw new Error("capture coverage contains duplicate queries");
  const expectedQueries = lockedQueryCoverageTerms(String(row.canonical_term), JSON.parse(String(row.aliases_json)) as string[]);
  const coveredQueries = input.coverage.map((item) => normalizeName(item.normalizedQuery)).sort();
  if (stableJson(expectedQueries) !== stableJson(coveredQueries)) throw new Error("capture coverage does not exactly match the locked query plan");
  const producerEnvelope = await readEvidenceEnvelope(env.EVIDENCE, input.evidence);
  if (producerEnvelope.checkId !== checkId || producerEnvelope.kind !== "producer") throw new Error("producer evidence identity mismatch");
  if (producerEnvelope.document.claim?.checkId !== checkId || producerEnvelope.document.claim?.queryPlanHash !== input.queryPlanHash) throw new Error("producer evidence is not bound to the claimed query plan");
  const recomputedCandidateSetHash = await digestHex(stableJson(input.candidates.map(({ evidenceHash: _evidenceHash, ...candidate }) => candidate)));
  if (recomputedCandidateSetHash !== input.candidateSetHash) throw new Error("candidate set hash does not match the complete normalized candidates");
  if (input.coverage.some((item) => item.evidenceHash !== input.evidence.sha256)) throw new Error("coverage is not bound to the producer evidence object");
  const evidenceId = await deterministicId("ingredient-producer-evidence", checkId, input.evidence.sha256);
  const statements: D1PreparedStatement[] = [env.DB.prepare(`INSERT INTO ingredient_evidence_refs
    (id, store_check_id, kind, object_key, sha256, byte_length, content_type, observed_at, source_url)
    VALUES (?1, ?2, 'query', ?3, ?4, ?5, ?6, ?7, ?8) ON CONFLICT(store_check_id, kind, sha256) DO NOTHING`)
    .bind(evidenceId, checkId, input.evidence.objectKey, input.evidence.sha256, input.evidence.byteLength,
      input.evidence.contentType, input.evidence.observedAt, input.evidence.sourceUrl),
  // A producer generation is a complete frozen search, not an append. Replace
  // the prior derived projection atomically so corrected captures cannot be
  // ranked against stale candidates or stale query coverage during QA.
  env.DB.prepare("DELETE FROM ingredient_query_coverage WHERE store_check_id = ?1").bind(checkId),
  env.DB.prepare("DELETE FROM ingredient_store_candidates WHERE store_check_id = ?1").bind(checkId)];
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
  for (const candidate of input.candidates) {
    const candidateId = await deterministicId("ingredient-targeted-candidate", checkId, candidate.productId, candidate.evidenceHash);
    statements.push(env.DB.prepare(`INSERT INTO ingredient_store_candidates
      (id, store_check_id, product_id, retailer_product_key, product_name, product_url, seller_name, fulfillment_state,
       availability_state, package_text, package_price_minor, normalized_basis_unit, normalized_basis_qty_micros,
       per_unit_micros, offer_kind, valid_from, valid_to, loyalty_required, membership_required, eligible,
       rejection_codes_json, evidence_hash, producer_evidence_hash, originating_query)
      VALUES (?1, ?2, ?3, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?21, ?22)
      ON CONFLICT(store_check_id, retailer_product_key, evidence_hash) DO NOTHING`)
      .bind(candidateId, checkId, candidate.productId, candidate.productName, candidate.sourceUrl, candidate.sellerName,
        candidate.fulfillmentMode, candidate.availabilityText, candidate.packageText, candidate.packagePriceMinor,
        candidate.normalizedBasisUnit, candidate.normalizedBasisQtyMicros, candidate.perUnitMicros, candidate.offerKind,
        candidate.validFrom, candidate.validTo, candidate.loyaltyRequired ? 1 : 0, candidate.membershipRequired ? 1 : 0,
        candidate.eligible ? 1 : 0, stableJson(candidate.rejectionCodes), candidate.evidenceHash,
        input.result.queryTerms.join(" | ")));
  }
  statements.push(env.DB.prepare(`UPDATE ingredient_store_checks SET state = 'qa_pending', operational_state = 'qa_queued',
    capture_result_json = ?4, candidate_set_hash = ?5, producer_evidence_id = ?6, producer_version = ?7,
    capture_completed_at = CURRENT_TIMESTAMP, evidence_generation = evidence_generation + 1,
    lease_owner = NULL, lease_expires_at = NULL, heartbeat_at = NULL, lease_lane = NULL,
    last_error = NULL, last_progress_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
    WHERE id = ?1 AND state = 'leased' AND lease_owner = ?2 AND lease_generation = ?3`)
    .bind(checkId, input.owner, input.leaseGeneration, stableJson(input.result), input.candidateSetHash, evidenceId, input.producerVersion));
  statements.push(env.DB.prepare(`INSERT INTO pipeline_stage_events
    (lane, aggregate_kind, aggregate_id, stage, event_kind, detail_json)
    VALUES ('pricing', 'store_check', ?1, 'capture', 'completed', ?2)`)
    .bind(checkId, stableJson({ storeLocationId: row.store_location_id, producerVersion: input.producerVersion,
      candidates: input.candidates.length, qualifying: input.result.qualifyingProductsExamined })));
  const results = await env.DB.batch(statements);
  if ((results.at(-2)?.meta.changes ?? 0) !== 1) throw new Error("capture completion lost its lease fence");
  return { checkId, state: "qa_queued" as const };
}

export async function completeIngredientStoreQa(env: Pick<WorkerEnv, "DB" | "EVIDENCE">, checkId: string, inputValue: unknown): Promise<IngredientAggregate> {
  const input: QaComplete = ingredientStoreQaCompleteSchema.parse(inputValue);
  const row = await env.DB.prepare(`SELECT check_row.pricing_job_id, check_row.lease_owner, check_row.lease_generation,
      check_row.lease_lane, check_row.query_plan_hash, check_row.capture_result_json, check_row.candidate_set_hash,
      check_row.producer_evidence_id, job.commodity_proposal_json FROM ingredient_store_checks check_row
      JOIN ingredient_pricing_jobs job ON job.id = check_row.pricing_job_id
      WHERE check_row.id = ?1 AND check_row.state = 'leased'`).bind(checkId).first<Record<string, unknown>>();
  if (!row || row.lease_owner !== input.owner || Number(row.lease_generation) !== input.leaseGeneration || row.lease_lane !== "qa") {
    throw new Error("QA completion rejected by lease fence or lane boundary");
  }
  if (!row.capture_result_json || !row.producer_evidence_id) throw new Error("QA has no frozen producer evidence");
  const result = JSON.parse(String(row.capture_result_json)) as { outcome: string; searchComplete: boolean; locationVerified: boolean; priceModeVerified: boolean; qualifyingProductsExamined: number };
  if (input.verdict !== "ambiguous" && input.verdict !== result.outcome) throw new Error("QA verdict disagrees with captured outcome");
  if (input.verdict !== "ambiguous" && (!result.searchComplete || !result.locationVerified || !result.priceModeVerified)) throw new Error("QA cannot verify incomplete capture");
  if (input.verdict === "priced" && result.qualifyingProductsExamined < 1) throw new Error("priced QA requires a qualifying candidate");
  if (input.verdict === "not_found" && result.qualifyingProductsExamined !== 0) throw new Error("not-found QA requires zero qualifying candidates");
  const coverage = await env.DB.prepare(`SELECT COUNT(*) AS count FROM ingredient_query_coverage
    WHERE store_check_id = ?1 AND complete = 1 AND end_of_results_proven = 1
      AND location_verified = 1 AND price_mode_verified = 1 AND expires_at > CURRENT_TIMESTAMP`).bind(checkId).first<{ count: number }>();
  if (Number(coverage?.count ?? 0) < 1) throw new Error("QA requires current complete query coverage");
  const candidates = await env.DB.prepare(`SELECT product_id, product_name, product_url, package_price_minor,
      normalized_basis_unit, normalized_basis_qty_micros, per_unit_micros, eligible
    FROM ingredient_store_candidates WHERE store_check_id = ?1 ORDER BY eligible DESC, per_unit_micros, product_id`).bind(checkId).all<Record<string, unknown>>();
  const eligible = candidates.results.filter((candidate) => Number(candidate.eligible) === 1);
  if (input.verdict === "not_found" && eligible.length !== 0) throw new Error("not-found QA cannot ignore an eligible candidate");
  if (input.verdict === "priced") {
    const winner = eligible[0];
    const captured = JSON.parse(String(row.capture_result_json)) as Record<string, unknown>;
    if (!winner || winner.product_name !== captured.productName || winner.product_url !== captured.sourceUrl
      || Number(winner.package_price_minor) !== Number(captured.packagePriceMinor)
      || Number(winner.per_unit_micros) !== Number(captured.perUnitMicros)
      || winner.normalized_basis_unit !== captured.normalizedBasisUnit) throw new Error("QA winner is not the cheapest frozen eligible candidate");
  }
  const verifierEnvelope = await readEvidenceEnvelope(env.EVIDENCE, input.verifierEvidence);
  if (verifierEnvelope.checkId !== checkId || verifierEnvelope.kind !== "verifier") throw new Error("verifier evidence identity mismatch");
  if (verifierEnvelope.document.claim?.checkId !== checkId || verifierEnvelope.document.claim?.queryPlanHash !== row.query_plan_hash) throw new Error("verifier evidence is not bound to the claimed query plan");
  const verification = verifierEnvelope.document.verification as Record<string, any> | undefined;
  if (!verification?.canary?.locationVerified || !verification?.canary?.priceModeVerified) throw new Error("verifier evidence lacks fresh Omaha location/mode proof");
  if (Date.parse(input.verifierEvidence.observedAt) <= Date.parse(String((result as Record<string, unknown>).checkedAt))) throw new Error("verifier evidence must be newer than producer capture");
  if (input.verdict === "priced") {
    const captured = JSON.parse(String(row.capture_result_json)) as Record<string, unknown>;
    const reproduced = Array.isArray(verification.verifications) && verification.verifications.some((item: Record<string, unknown>) => item.outcome === "observed"
      && item.productKey === captured.sourceUrl && item.name === captured.productName && item.sizeText === captured.packageText
      && Number(item.purchasePriceMinor) === Number(captured.packagePriceMinor));
    if (!reproduced) throw new Error("independent verifier did not reproduce the frozen winner identity, size, and price");
  } else if (input.verdict === "not_found") {
    const captured = JSON.parse(String(row.capture_result_json)) as { queryTerms?: string[] };
    const terms = Array.isArray(verification.terms) ? verification.terms : [];
    const complete = new Set(terms.filter(isCompleteVerificationTerm)
      .map((item: Record<string, unknown>) => String(item.query).trim().toLowerCase()));
    if (!(captured.queryTerms ?? []).every((term) => complete.has(term.trim().toLowerCase()))) throw new Error("independent verifier did not reproduce complete no-match coverage");
    const proposal = JSON.parse(String(row.commodity_proposal_json ?? "null")) as { include?: string[]; exclude?: string[] } | null;
    if (!proposal || !Array.isArray(proposal.include) || !Array.isArray(proposal.exclude)) throw new Error("QA lacks the locked ingredient definition");
    const include = proposal.include.map((pattern) => new RegExp(pattern.replace(/^\(\?i\)/, ""), "i"));
    const exclude = proposal.exclude.map((pattern) => new RegExp(pattern.replace(/^\(\?i\)/, ""), "i"));
    const eligibleLike = (Array.isArray(verification.rows) ? verification.rows : []).some((item: Record<string, any>) => {
      const offer = item?._capture?.offer ?? {};
      const name = String(offer.productName ?? item.n ?? item.name ?? "");
      const availability = offer.availability ?? {};
      const price = Number(offer.purchasePriceMinor ?? item?._capture?.visible?.priceMinor);
      const size = String(offer.sizeText ?? item.size ?? "").trim();
      return include.some((rule) => rule.test(name)) && !exclude.some((rule) => rule.test(name))
        && availability.eligible === true && availability.status === "in_stock" && Number.isSafeInteger(price) && price > 0 && size.length > 0;
    });
    if (eligibleLike) throw new Error("independent verifier found an eligible exact candidate in the repeated result envelope");
  }
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
      result_json = capture_result_json, evidence_id = producer_evidence_id,
      qa_attestation_id = ?6, verifier_evidence_id = ?7, verifier_version = ?8, qa_generation = qa_generation + 1,
      qa_completed_at = CURRENT_TIMESTAMP, lease_owner = NULL, lease_expires_at = NULL, heartbeat_at = NULL,
      lease_lane = NULL, last_error = ?9, last_progress_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND state = 'leased' AND lease_owner = ?2 AND lease_generation = ?3`)
      .bind(checkId, input.owner, input.leaseGeneration, terminal, input.verdict === "ambiguous" ? null : input.verdict,
        qaId, verifierEvidenceId, input.verifierVersion, input.verdict === "ambiguous" ? input.findings.join("; ") : null),
    env.DB.prepare(`INSERT INTO pipeline_stage_events
      (lane, aggregate_kind, aggregate_id, stage, event_kind, detail_json)
      VALUES ('pricing', 'store_check', ?1, 'qa', ?2, ?3)`)
      .bind(checkId, input.verdict === "ambiguous" ? "attention_required" : "completed",
        stableJson({ verdict: input.verdict, verifierVersion: input.verifierVersion, findings: input.findings })),
  ];
  const results = await env.DB.batch(statements);
  if ((results.at(-2)?.meta.changes ?? 0) !== 1) throw new Error("QA completion lost its lease fence");
  return sealAggregateIfTerminal(env, String(row.pricing_job_id));
}

/**
 * Independent QA must be able to return a bad frozen capture to collection
 * without turning it into a terminal result. Raw R2 evidence and audit events
 * remain immutable; only the derived candidate/coverage projection is cleared
 * so the next fenced producer generation cannot accidentally rank stale rows.
 */
export async function rejectIngredientStoreQa(env: Pick<WorkerEnv, "DB">, checkId: string, input: QaReject) {
  const row = await env.DB.prepare(`SELECT pricing_job_id, lease_owner, lease_generation, lease_lane
    FROM ingredient_store_checks WHERE id = ?1 AND state = 'leased'`).bind(checkId).first<Record<string, unknown>>();
  if (!row || row.lease_owner !== input.owner || Number(row.lease_generation) !== input.leaseGeneration || row.lease_lane !== "qa") {
    throw new Error("QA rejection rejected by lease fence or lane boundary");
  }
  const results = await env.DB.batch([
    env.DB.prepare("DELETE FROM ingredient_query_coverage WHERE store_check_id = ?1").bind(checkId),
    env.DB.prepare("DELETE FROM ingredient_store_candidates WHERE store_check_id = ?1").bind(checkId),
    env.DB.prepare(`UPDATE ingredient_store_checks SET state = 'targeted_refresh', operational_state = 'capture_queued',
      terminal_outcome = NULL, capture_result_json = NULL, candidate_set_hash = NULL, producer_evidence_id = NULL,
      verifier_evidence_id = NULL, verifier_version = NULL, qa_attestation_id = NULL,
      lease_owner = NULL, lease_expires_at = NULL, heartbeat_at = NULL, lease_lane = NULL,
      error_class = 'qa_rejected', last_error = ?4, state_version = state_version + 1,
      next_attempt_at = CURRENT_TIMESTAMP, last_progress_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND state = 'leased' AND lease_owner = ?2 AND lease_generation = ?3 AND lease_lane = 'qa'`)
      .bind(checkId, input.owner, input.leaseGeneration, input.reason),
    env.DB.prepare(`INSERT INTO pipeline_stage_events
      (lane, aggregate_kind, aggregate_id, stage, event_kind, detail_json)
      VALUES ('pricing', 'store_check', ?1, 'qa', 'rejected_to_capture', ?2)`)
      .bind(checkId, stableJson({ reason: input.reason, validatorVersion: input.validatorVersion })),
  ]);
  if ((results.at(-2)?.meta.changes ?? 0) !== 1) throw new Error("QA rejection lost its lease fence");
  return { checkId, pricingJobId: String(row.pricing_job_id), state: "capture_queued" as const };
}
