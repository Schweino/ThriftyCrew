import { z } from "zod";

export const isoDateTime = z.iso.datetime({ offset: true });
export const nonEmptyId = z.string().min(1).max(160).regex(/^[a-zA-Z0-9][a-zA-Z0-9._:-]*$/);
export const sha256Hex = z.string().regex(/^[a-f0-9]{64}$/);

export const coverageMode = z.enum(["full", "partial", "targeted", "ad_only"]);
export const captureTermOutcome = z.enum(["success", "empty", "rejected", "blocked", "not_attempted"]);
export const observationKind = z.enum(["sale", "everyday", "markdown", "member"]);
export const basisUnit = z.enum([
  "lb",
  "oz",
  "fl_oz",
  "each",
  "dozen",
  "gal",
  "qt",
  "pt",
  "liter",
  "ml",
  "gram",
  "kg",
]);

export const captureBatchCreateSchema = z
  .object({
    sourceId: nonEmptyId,
    coverageMode,
    capturedFrom: isoDateTime,
    capturedTo: isoDateTime,
    validFrom: isoDateTime.optional(),
    validTo: isoDateTime.optional(),
    expectedTerms: z.number().int().nonnegative().optional(),
    expectedPages: z.number().int().nonnegative().optional(),
    marketVerified: z.boolean(),
    locationVerified: z.boolean(),
    priceModeVerified: z.boolean(),
    idempotencyKey: nonEmptyId,
  })
  .superRefine((value, context) => {
    if (value.capturedTo < value.capturedFrom) {
      context.addIssue({ code: "custom", path: ["capturedTo"], message: "must not precede capturedFrom" });
    }
    if (value.validFrom && value.validTo && value.validTo < value.validFrom) {
      context.addIssue({ code: "custom", path: ["validTo"], message: "must not precede validFrom" });
    }
    if (value.coverageMode === "full" && value.expectedTerms === undefined && value.expectedPages === undefined) {
      context.addIssue({ code: "custom", path: ["coverageMode"], message: "full batches need an expected term or page envelope" });
    }
  });

export const captureTermSchema = z.object({
  termKey: nonEmptyId,
  ordinal: z.number().int().nonnegative(),
  outcome: captureTermOutcome,
  rowCount: z.number().int().nonnegative(),
  reason: z.string().max(1000).optional(),
});

export const observationInputSchema = z
  .object({
    externalProductKey: z.string().min(1).max(300),
    name: z.string().min(1).max(1000),
    sizeText: z.string().max(500),
    productUrl: z.url().max(3000).optional(),
    imageUrl: z.url().max(3000).optional(),
    taxonomyPath: z.string().min(1).max(3000).optional(),
    package: z.record(z.string(), z.unknown()).default({}),
    termKey: nonEmptyId.optional(),
    kind: observationKind,
    currency: z.string().length(3).regex(/^[A-Z]{3}$/).default("USD"),
    purchasePriceMinor: z.number().int().nonnegative(),
    regularPriceMinor: z.number().int().nonnegative().optional(),
    purchaseQuantity: z.number().int().positive().default(1),
    packageCount: z.number().int().positive().default(1),
    capturedBasisUnit: basisUnit,
    capturedBasisQtyMicros: z.number().int().positive(),
    normalizedBasisUnit: basisUnit,
    normalizedBasisQtyMicros: z.number().int().positive(),
    perUnitMicros: z.number().int().nonnegative(),
    basisOptions: z.array(z.object({
      unit: basisUnit,
      quantityMicros: z.number().int().positive(),
      perUnitMicros: z.number().int().nonnegative(),
      source: z.string().min(1).max(100),
    })).max(12).optional(),
    loyaltyRequired: z.boolean().default(false),
    membershipRequired: z.boolean().default(false),
    rawPriceText: z.string().min(1).max(500),
    rawSizeText: z.string().max(500),
    capturedAt: isoDateTime,
    validFrom: isoDateTime.optional(),
    validTo: isoDateTime.optional(),
    evidenceObjectId: nonEmptyId.optional(),
    sourcePayloadKey: z.string().max(1000).optional(),
  })
  .superRefine((value, context) => {
    if (value.regularPriceMinor !== undefined && value.regularPriceMinor < value.purchasePriceMinor) {
      context.addIssue({ code: "custom", path: ["regularPriceMinor"], message: "cannot be lower than purchase price" });
    }
    if (value.validFrom && value.validTo && value.validTo < value.validFrom) {
      context.addIssue({ code: "custom", path: ["validTo"], message: "must not precede validFrom" });
    }
  });

export const observationChunkSchema = z.object({
  observations: z.array(observationInputSchema).min(1).max(100),
});

export const captureBatchSealSchema = z.object({
  terms: z.array(captureTermSchema).max(2000),
  evidenceManifestKey: z.string().min(1).max(1000).optional(),
});

export const directCaptureArtifactSchema = z.object({
  version: z.literal(1),
  sourceId: nonEmptyId,
  coverageMode,
  capturedFrom: isoDateTime,
  capturedTo: isoDateTime,
  validFrom: isoDateTime.optional(),
  validTo: isoDateTime.optional(),
  expectedTerms: z.number().int().nonnegative().optional(),
  expectedPages: z.number().int().nonnegative().optional(),
  marketVerified: z.boolean(),
  locationVerified: z.boolean(),
  priceModeVerified: z.boolean(),
  idempotencyKey: nonEmptyId,
  terms: z.array(captureTermSchema).max(2000),
  observations: z.array(observationInputSchema).min(1).max(100_000),
  evidence: z.object({
    kind: z.enum(["screenshot", "flyer_page", "raw_payload", "manifest"]),
    contentType: z.string().min(1).max(200),
  }).optional(),
  audit: z.record(z.string(), z.unknown()).default({}),
}).superRefine((value, context) => {
  if (value.capturedTo < value.capturedFrom) context.addIssue({ code: "custom", path: ["capturedTo"], message: "must not precede capturedFrom" });
  if (value.expectedTerms !== undefined && value.terms.length !== value.expectedTerms) context.addIssue({ code: "custom", path: ["terms"], message: "term ledger does not match expectedTerms" });
  const ordinals = new Set(value.terms.map((term) => term.ordinal));
  if (ordinals.size !== value.terms.length) context.addIssue({ code: "custom", path: ["terms"], message: "term ordinals must be unique" });
});

export const evidenceMetadataSchema = z.object({
  id: nonEmptyId,
  kind: z.enum(["screenshot", "flyer_page", "raw_payload", "manifest"]),
  sha256: sha256Hex,
  expiresAt: isoDateTime.optional(),
});

export const configurationCreateSchema = z.object({
  id: nonEmptyId,
  sourceCommit: z.string().min(1).max(200),
  contentHash: sha256Hex,
  expectedCategories: z.number().int().nonnegative(),
  expectedCommodities: z.number().int().nonnegative(),
  expectedRules: z.number().int().nonnegative(),
  expectedKnownWrong: z.number().int().nonnegative().default(0),
});

export const configurationCategoriesChunkSchema = z.object({
  categories: z.array(z.object({
    id: nonEmptyId,
    label: z.string().min(1).max(300),
    sortOrder: z.number().int(),
  })).min(1).max(100),
});

export const configurationCommoditiesChunkSchema = z.object({
  commodities: z.array(z.object({
    id: nonEmptyId,
    label: z.string().min(1).max(500),
    basisUnit,
    categoryId: nonEmptyId,
    include: z.array(z.string().min(1).max(1000)).max(300),
    exclude: z.array(z.string().min(1).max(1000)).max(300),
  })).min(1).max(25),
});

export const configurationKnownWrongChunkSchema = z.object({
  rules: z.array(z.object({
    id: nonEmptyId,
    commodityId: nonEmptyId,
    storeLocationId: nonEmptyId.optional(),
    externalProductKey: z.string().min(1).max(500).optional(),
    normalizedName: z.string().min(1).max(1000).optional(),
    ruling: z.string().min(1).max(2000),
    evidence: z.string().min(1).max(10_000),
  }).refine((value) => value.externalProductKey !== undefined || value.normalizedName !== undefined, {
    message: "known-wrong rules need an external product key or normalized name",
  })).min(1).max(100),
});

export const matchDecisionsChunkSchema = z.object({
  decisions: z.array(z.object({
    productId: nonEmptyId,
    commodityId: nonEmptyId,
    configurationId: nonEmptyId,
    decidedBy: z.enum(["rule", "aisle", "manual", "legacy_bridge"]),
    reason: z.string().min(1).max(2000),
  })).min(1).max(100),
});

export const matchDecisionReconcileSchema = z.object({
  batchId: nonEmptyId,
  configurationId: nonEmptyId,
  retainedProductIds: z.array(nonEmptyId).max(50_000),
});

export const matchRunSchema = z.object({
  id: nonEmptyId,
  batchId: nonEmptyId,
  configurationId: nonEmptyId,
  inputHash: sha256Hex,
  productCount: z.number().int().nonnegative(),
  matchedCount: z.number().int().nonnegative(),
  unmatchedCount: z.number().int().nonnegative(),
  collisionCount: z.number().int().nonnegative(),
  aisleRejectedCount: z.number().int().nonnegative(),
  detail: z.record(z.string(), z.unknown()).default({}),
}).superRefine((value, context) => {
  const classified = value.matchedCount + value.unmatchedCount + value.collisionCount + value.aisleRejectedCount;
  if (classified !== value.productCount) context.addIssue({ code: "custom", path: ["productCount"], message: "match classifications must account for every product" });
});

export const jobRunCreateSchema = z.object({
  id: nonEmptyId,
  job: nonEmptyId,
  triggerKind: z.enum(["schedule", "dispatch", "watchdog", "operator", "test"]),
  scheduledFor: isoDateTime.optional(),
  startedAt: isoDateTime.optional(),
  executorRunId: z.string().min(1).max(300).optional(),
  promptHash: sha256Hex.optional(),
  inputHash: sha256Hex.optional(),
  modelId: z.string().min(1).max(200).optional(),
  input: z.record(z.string(), z.unknown()).default({}),
});

export const jobRunUpdateSchema = z.object({
  status: z.enum(["started", "completed", "failed", "missed", "timed_out", "cancelled"]),
  startedAt: isoDateTime.optional(),
  heartbeatAt: isoDateTime.optional(),
  finishedAt: isoDateTime.optional(),
  outputHash: sha256Hex.optional(),
  usage: z.object({
    inputTokens: z.number().int().nonnegative().default(0),
    outputTokens: z.number().int().nonnegative().default(0),
    cacheReadTokens: z.number().int().nonnegative().default(0),
    cacheWriteTokens: z.number().int().nonnegative().default(0),
    costMicrousd: z.number().int().nonnegative().default(0),
  }).default({ inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, costMicrousd: 0 }),
  stats: z.record(z.string(), z.unknown()).default({}),
  error: z.string().max(10_000).optional(),
}).superRefine((value, context) => {
  if (["completed", "failed", "missed", "timed_out", "cancelled"].includes(value.status) && !value.finishedAt) {
    context.addIssue({ code: "custom", path: ["finishedAt"], message: "terminal job states require finishedAt" });
  }
});

export const scheduleEntrySchema = z.object({
  id: nonEmptyId,
  cron: z.string().min(5).max(256),
  executor: z.enum(["github-actions", "worker-cron", "cloudflare-workflow", "pc"]),
  maxGapMinutes: z.number().int().positive(),
  owner: z.string().min(1).max(160),
  proof: z.string().min(1).max(500),
  dispatchOnGap: z.boolean().default(false),
});

export const scheduleDocumentSchema = z.object({
  version: z.number().int().positive(),
  timezone: z.string().min(1).max(100),
  schedules: z.array(scheduleEntrySchema).min(1).max(100),
}).superRefine((value, context) => {
  const ids = new Set<string>();
  value.schedules.forEach((schedule, index) => {
    if (ids.has(schedule.id)) context.addIssue({ code: "custom", path: ["schedules", index, "id"], message: "schedule ids must be unique" });
    ids.add(schedule.id);
  });
});

export const jobDispatchSchema = z.object({
  idempotencyKey: nonEmptyId,
  reason: z.string().min(1).max(2000),
  ref: z.string().min(1).max(300).default("main"),
});

export const engineParityReportSchema = z.object({
  runId: nonEmptyId,
  mode: z.enum(["legacy", "direct", "all"]),
  observedAt: isoDateTime,
  currentReleaseId: nonEmptyId,
  configurationId: nonEmptyId,
  inputHash: sha256Hex,
  inputBatchIds: z.array(nonEmptyId).min(1).max(100),
  comparedCells: z.number().int().nonnegative(),
  diffCount: z.number().int().nonnegative(),
  diffs: z.array(z.object({
    key: z.string().min(1).max(500),
    current: z.record(z.string(), z.unknown()).nullable(),
    native: z.record(z.string(), z.unknown()).nullable(),
    reason: z.string().min(1).max(1000),
  })).max(500),
});

export const releaseCreateSchema = z.object({
  id: nonEmptyId,
  marketId: nonEmptyId,
  configurationId: nonEmptyId,
  engineRunId: nonEmptyId.optional(),
  inputManifest: z.record(z.string(), z.unknown()),
  inputBatchIds: z.array(nonEmptyId).min(1).max(100).refine((ids) => new Set(ids).size === ids.length, {
    message: "input batch ids must be unique",
  }),
  inputHash: sha256Hex,
  summary: z.object({
    expectedCommodities: z.number().int().nonnegative(),
    expectedStores: z.number().int().positive(),
    expectedRecipes: z.number().int().nonnegative(),
    expectedFreeRotation: z.number().int().nonnegative().default(0),
  }),
});

export const releaseCellSchema = z.object({
  commodityId: nonEmptyId,
  storeLocationId: nonEmptyId,
  observationId: nonEmptyId.optional(),
  status: z.enum(["priced", "missing", "not_carried", "held"]),
  isCrown: z.boolean(),
  displayPerUnitMicros: z.number().int().nonnegative().optional(),
  displayUnit: basisUnit.optional(),
  reason: z.record(z.string(), z.unknown()).default({}),
}).superRefine((value, context) => {
  if (value.status === "priced" && (!value.observationId || value.displayPerUnitMicros === undefined || !value.displayUnit)) {
    context.addIssue({ code: "custom", message: "priced cells require observation, amount and unit" });
  }
});

export const releaseCellsChunkSchema = z.object({ cells: z.array(releaseCellSchema).min(1).max(250) });

export const recipeCostSchema = z.object({
  recipeSlug: nonEmptyId,
  status: z.enum(["complete", "incomplete", "held"]),
  batchCostMinor: z.number().int().nonnegative().optional(),
  servingCostMinor: z.number().int().nonnegative().optional(),
  servings: z.number().int().positive(),
  missingIngredients: z.array(z.string().min(1).max(500)).default([]),
  detail: z.record(z.string(), z.unknown()).default({}),
}).superRefine((value, context) => {
  if (value.status === "complete" && (value.batchCostMinor === undefined || value.servingCostMinor === undefined)) {
    context.addIssue({ code: "custom", message: "complete recipes require batch and serving costs" });
  }
});

export const recipeCostsChunkSchema = z.object({ costs: z.array(recipeCostSchema).min(1).max(250) });

export const releasePayloadSchema = z.object({
  kind: z.enum(["board", "feed", "top5", "free_rotation", "recipes"]),
  payload: z.unknown(),
  contentHash: sha256Hex,
});

export const releaseFreeRotationChunkSchema = z.object({
  entries: z.array(z.object({
    recipeSlug: nonEmptyId,
    intendedVisibility: z.enum(["public", "members", "paid"]),
    protein: z.string().min(1).max(100).optional(),
    rank: z.number().int().positive().optional(),
  })).max(1000),
});

export const releaseTop5ChunkSchema = z.object({
  entries: z.array(z.object({
    protein: z.string().min(1).max(100),
    rank: z.number().int().positive().max(100),
    recipeSlug: nonEmptyId,
    servingCostMinor: z.number().int().nonnegative(),
  })).max(1000),
});

export const telemetryEventSchema = z.object({
  event: z.enum(["view", "tool_use", "signup_click", "join_attempt"]),
  path: z.string().min(1).max(500).startsWith("/"),
  memberTier: z.enum(["anonymous", "free", "paid", "unknown"]),
  releaseId: nonEmptyId.optional(),
  product: z.string().min(1).max(160).optional(),
});

export const accuracyDrawCreateSchema = z.object({
  marketId: nonEmptyId.default("omaha"),
  seed: z.string().min(8).max(200),
  protocolVersion: nonEmptyId.default("blind-cell-v1"),
  sampleSize: z.number().int().min(1).max(500).default(100),
  dueAt: isoDateTime,
});

export const accuracyVerdictsSchema = z.object({
  drawId: nonEmptyId,
  verdicts: z.array(z.object({
    ordinal: z.number().int().nonnegative(),
    verdict: z.enum(["right", "wrong", "cannot_tell"]),
    verifiedAt: isoDateTime,
    evidence: z.record(z.string(), z.unknown()).default({}),
  })).min(1).max(500),
});

export const triageResolveSchema = z.object({
  status: z.enum(["planned", "resolved", "needs_operator"]),
  planRef: z.string().min(1).max(1000).optional(),
  resolution: z.record(z.string(), z.unknown()).default({}),
});

export const restoreDrillRecordSchema = z.object({
  id: nonEmptyId,
  backupId: nonEmptyId,
  scratchDatabaseId: nonEmptyId,
  dumpSha256: sha256Hex,
  status: z.enum(["started", "passed", "failed"]),
  startedAt: isoDateTime,
  finishedAt: isoDateTime.optional(),
  evidence: z.record(z.string(), z.unknown()).default({}),
}).superRefine((value, context) => {
  if (value.status !== "started" && !value.finishedAt) {
    context.addIssue({ code: "custom", path: ["finishedAt"], message: "terminal restore drill states require finishedAt" });
  }
  if (value.finishedAt && value.finishedAt < value.startedAt) {
    context.addIssue({ code: "custom", path: ["finishedAt"], message: "must not precede startedAt" });
  }
});

export const releaseGuardResultSchema = z.object({
  guardId: nonEmptyId,
  status: z.enum(["pass", "fail", "warn", "blind", "error"]),
  eligibleCount: z.number().int().nonnegative(),
  examinedCount: z.number().int().nonnegative(),
  findings: z.array(z.object({ key: nonEmptyId, message: z.string().min(1), evidence: z.record(z.string(), z.unknown()).default({}) })).default([]),
  detail: z.record(z.string(), z.unknown()).default({}),
}).superRefine((value, context) => {
  if (value.examinedCount > value.eligibleCount) context.addIssue({ code: "custom", message: "examined cannot exceed eligible" });
  if (value.eligibleCount > 0 && value.examinedCount === 0 && value.status === "pass") {
    context.addIssue({ code: "custom", message: "a blind guard cannot pass" });
  }
});

export type CaptureBatchCreate = z.infer<typeof captureBatchCreateSchema>;
export type ObservationInput = z.infer<typeof observationInputSchema>;
export type ConfigurationCreate = z.infer<typeof configurationCreateSchema>;
export type ReleaseCreate = z.infer<typeof releaseCreateSchema>;
export type ReleaseCell = z.infer<typeof releaseCellSchema>;
export type RecipeCost = z.infer<typeof recipeCostSchema>;
export type ReleaseGuardResult = z.infer<typeof releaseGuardResultSchema>;
export type TelemetryEvent = z.infer<typeof telemetryEventSchema>;
export type AccuracyDrawCreate = z.infer<typeof accuracyDrawCreateSchema>;
export type AccuracyVerdicts = z.infer<typeof accuracyVerdictsSchema>;
export type DirectCaptureArtifact = z.infer<typeof directCaptureArtifactSchema>;
export type EngineParityReport = z.infer<typeof engineParityReportSchema>;
export type RestoreDrillRecord = z.infer<typeof restoreDrillRecordSchema>;
