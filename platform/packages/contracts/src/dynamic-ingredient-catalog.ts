import { z } from "zod";

export const OMAHA_STORE_LOCATION_IDS = [
  "aldi-omaha-446-048",
  "bakers-saddle-creek",
  "family-fare-omaha-6401",
  "fareway-omaha-043",
  "hy-vee-omaha-1465",
  "sams-omaha",
  "walmart-omaha",
] as const;

export const catalogIngredientIdentitySchema = z.object({
  canonicalName: z.string().trim().min(1).max(300),
  displayName: z.string().trim().min(1).max(300),
  aliases: z.array(z.string().trim().min(1).max(300)).max(200),
  acceptedForms: z.array(z.string().trim().min(1).max(300)).max(100),
  excludedForms: z.array(z.string().trim().min(1).max(300)).max(100),
  requiredQualifiers: z.array(z.string().trim().min(1).max(300)).max(100),
  optionalQualifiers: z.array(z.string().trim().min(1).max(300)).max(100),
  unitDimension: z.enum(["weight", "volume", "count", "other"]),
  basisUnit: z.string().trim().min(1).max(40),
  packageNormalizationRules: z.array(z.string().trim().min(1).max(500)).max(100),
  queryTerms: z.array(z.string().trim().min(1).max(300)).min(1).max(100),
  storeQueryVariants: z.record(z.string(), z.array(z.string().trim().min(1).max(300)).max(30)),
  sourceOccurrences: z.array(z.object({ recipeCandidateId: z.string().min(1), sourceOccurrenceId: z.string().min(1) })).min(1),
  plannerRunId: z.string().min(1),
  adjudication: z.object({ runId: z.string().min(1), decision: z.string().min(1) }).nullable(),
});

const evidenceRefSchema = z.object({ id: z.string().min(1), hash: z.string().regex(/^[a-f0-9]{64}$/) });

export const publicIngredientStoreRowSchema = z.discriminatedUnion("status", [
  z.object({
    status: z.literal("priced"), storeLocationId: z.enum(OMAHA_STORE_LOCATION_IDS), fulfillmentMode: z.string().min(1),
    retailerProductId: z.string().min(1), productName: z.string().min(1), brand: z.string().nullable(),
    packageCount: z.number().int().positive(), unitSizeMicros: z.number().int().positive(),
    totalQuantityMicros: z.number().int().positive(), unitDimension: z.string().min(1), basisUnit: z.string().min(1),
    shelfPriceMinor: z.number().int().nonnegative(), effectivePriceMinor: z.number().int().nonnegative(),
    unitPriceNumerator: z.number().int().nonnegative(), unitPriceDenominator: z.number().int().positive(),
    priceKind: z.enum(["regular", "sale", "ad", "member"]), validFrom: z.string().nullable(), validTo: z.string().nullable(),
    membershipRequired: z.boolean(), availability: z.string().min(1), productUrl: z.string().url(), capturedAt: z.string(),
    producerEvidence: evidenceRefSchema, verifierEvidence: evidenceRefSchema,
    queryCoverageHash: z.string().regex(/^[a-f0-9]{64}$/), candidateSetHash: z.string().regex(/^[a-f0-9]{64}$/),
    winningDecisionHash: z.string().regex(/^[a-f0-9]{64}$/),
  }),
  z.object({
    status: z.literal("not_found"), storeLocationId: z.enum(OMAHA_STORE_LOCATION_IDS), fulfillmentMode: z.string().min(1),
    attemptedQueries: z.array(z.string().min(1)).min(1), coverageType: z.enum(["full", "targeted_exhaustive"]),
    paginationProof: z.object({ endOfResults: z.literal(true), resultCount: z.number().int().nonnegative(), hash: z.string().regex(/^[a-f0-9]{64}$/) }),
    producerGenerationId: z.string().min(1), verifierGenerationId: z.string().min(1),
    excludedCandidates: z.array(z.object({ productId: z.string().min(1), reason: z.string().min(1) })),
    producerEvidence: evidenceRefSchema, verifierEvidence: evidenceRefSchema,
    capturedAt: z.string(), verifiedAt: z.string(),
  }),
]);

export const publicIngredientSnapshotSchema = z.object({
  ingredientId: z.string().min(1), definitionVersionId: z.string().min(1), slug: z.string().min(1),
  canonicalName: z.string().min(1), displayName: z.string().min(1), basisUnit: z.string().min(1),
  stores: z.array(publicIngredientStoreRowSchema).length(7).superRefine((rows, context) => {
    const ids = rows.map((row) => row.storeLocationId);
    if (new Set(ids).size !== 7 || OMAHA_STORE_LOCATION_IDS.some((id) => !ids.includes(id))) {
      context.addIssue({ code: "custom", message: "snapshot must contain exactly one row for each authoritative Omaha store" });
    }
    if (!rows.some((row) => row.status === "priced")) context.addIssue({ code: "custom", message: "publication requires at least one verified price" });
    for (const row of rows) if (row.producerEvidence.hash === row.verifierEvidence.hash) {
      context.addIssue({ code: "custom", message: `producer and verifier evidence must differ for ${row.storeLocationId}` });
    }
  }),
});

export type PublicIngredientSnapshot = z.infer<typeof publicIngredientSnapshotSchema>;
export type PublicIngredientStoreRow = z.infer<typeof publicIngredientStoreRowSchema>;
