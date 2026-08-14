import { z } from "zod";

export const pipelineExecutorKindSchema = z.enum(["codex_chatgpt", "browser_codex", "deterministic_node"]);
export const pipelineWorkStateSchema = z.enum([
  "queued", "claimed", "running", "blocked_challenge", "needs_operator", "succeeded",
  "failed_transient", "failed_permanent", "superseded",
]);

export const pipelineAgentRegistrationSchema = z.object({
  agentId: z.string().min(1), lane: z.enum(["recipe_source", "ingredient_pricing", "recipe_completion"]),
  role: z.string().min(1), executorKind: pipelineExecutorKindSchema,
  inputSchema: z.string().min(1), outputSchema: z.string().min(1), batchSize: z.number().int().min(1).max(50),
  maximumConcurrency: z.number().int().positive(), storeLocationId: z.string().min(1).optional(),
  leaseSeconds: z.number().int().min(30).max(900), heartbeatSeconds: z.number().int().min(5).max(30),
  retryPolicy: z.object({ maximumAttempts: z.number().int().min(1), baseDelayMs: z.number().int().nonnegative(), maximumDelayMs: z.number().int().positive() }),
  idempotencyKeyFormat: z.string().min(1), evidenceRequirements: z.array(z.string().min(1)),
  performanceBudgetMs: z.number().int().positive(),
  model: z.string().min(1).optional(), promptSha256: z.string().regex(/^[a-f0-9]{64}$/).optional(), evaluationHash: z.string().regex(/^[a-f0-9]{64}$/).optional(),
}).superRefine((value, context) => {
  if (value.executorKind === "codex_chatgpt" && (!value.model || !value.promptSha256 || !value.evaluationHash)) {
    context.addIssue({ code: "custom", message: "model-backed agents require model, prompt, and evaluation hashes" });
  }
  if (value.executorKind !== "codex_chatgpt" && (value.model || value.promptSha256 || value.evaluationHash)) {
    context.addIssue({ code: "custom", message: "deterministic/browser registrations must not carry model billing metadata" });
  }
});

export const pipelineTelemetrySchema = z.object({
  correlationId: z.string().min(1), queueWaitMs: z.number().int().nonnegative(), activeComputeMs: z.number().int().nonnegative(),
  externalSourceWaitMs: z.number().int().nonnegative(), browserChallengeMs: z.number().int().nonnegative(), operatorBlockedMs: z.number().int().nonnegative(),
  d1ReadMs: z.number().int().nonnegative(), d1WriteMs: z.number().int().nonnegative(), modelMs: z.number().int().nonnegative(),
  retailerRequests: z.number().int().nonnegative(), searchTerms: z.number().int().nonnegative(), pagesExamined: z.number().int().nonnegative(),
  productsExamined: z.number().int().nonnegative(), candidateCount: z.number().int().nonnegative(),
  errorClassification: z.string().nullable(), challengeClassification: z.string().nullable(),
});

export type PipelineAgentRegistration = z.infer<typeof pipelineAgentRegistrationSchema>;
