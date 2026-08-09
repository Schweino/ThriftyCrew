export interface WorkerEnv {
  DB: D1Database;
  EVIDENCE: R2Bucket;
  ASSETS: Fetcher;
  FUNNEL_ANALYTICS?: AnalyticsEngineDataset;
  APP_ENV: string;
  PUBLIC_ORIGIN: string;
  MUTATION_KEYS?: string;
  GITHUB_OIDC_AUDIENCE?: string;
  GITHUB_OIDC_REPOSITORY?: string;
  GITHUB_OIDC_REPOSITORY_ID?: string;
  GITHUB_OIDC_WORKFLOW_REF?: string;
  GHOST_ADMIN_ORIGIN?: string;
  GHOST_ADMIN_KEY?: string;
}

export type MutationRole = "capture" | "engine" | "operator";

export interface MutationKeyRecord {
  secret: string;
  role: MutationRole;
  sourceIds?: string[];
}

export interface MutationIdentity extends MutationKeyRecord {
  agentId: string;
  authMethod: "hmac" | "github_oidc";
}
