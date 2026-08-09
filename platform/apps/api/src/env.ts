export interface WorkerEnv {
  DB: D1Database;
  EVIDENCE: R2Bucket;
  BACKUPS: R2Bucket;
  BACKUPS_SECONDARY: R2Bucket;
  BACKUP_WORKFLOW: Workflow;
  ASSETS: Fetcher;
  FUNNEL_ANALYTICS?: AnalyticsEngineDataset;
  APP_ENV: string;
  PUBLIC_ORIGIN: string;
  MUTATION_KEYS?: string;
  GITHUB_OIDC_AUDIENCE?: string;
  GITHUB_OIDC_REPOSITORY?: string;
  GITHUB_OIDC_REPOSITORY_ID?: string;
  GITHUB_OIDC_WORKFLOW_REF?: string;
  GITHUB_DISPATCH_TOKEN?: string;
  GITHUB_REPOSITORY?: string;
  GITHUB_WORKFLOW_FILE?: string;
  OPS_ALERT_URL?: string;
  OPS_ALERT_AUTH?: string;
  D1_REST_API_TOKEN?: string;
  CLOUDFLARE_ACCOUNT_ID?: string;
  D1_DATABASE_ID?: string;
  GHOST_ADMIN_ORIGIN?: string;
  GHOST_ADMIN_KEY?: string;
  GHOST_PUBLIC_ORIGIN?: string;
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
