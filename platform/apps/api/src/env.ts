export interface WorkerEnv {
  DB: D1Database;
  EVIDENCE: R2Bucket;
  BACKUPS: R2Bucket;
  BACKUPS_SECONDARY: R2Bucket;
  ARCHIVE: R2Bucket;
  BACKUP_WORKFLOW: Workflow;
  RESTORE_WORKFLOW: Workflow;
  CAPTURE_VALIDATION_WORKFLOW?: Workflow;
  ASSETS: Fetcher;
  FUNNEL_ANALYTICS?: AnalyticsEngineDataset;
  APP_ENV: string;
  PUBLIC_ORIGIN: string;
  MUTATION_KEYS?: string;
  GITHUB_OIDC_AUDIENCE?: string;
  GITHUB_OIDC_REPOSITORY?: string;
  GITHUB_OIDC_REPOSITORY_ID?: string;
  GITHUB_OIDC_WORKFLOW_REF?: string;
  GITHUB_OIDC_WORKFLOW_REFS?: string;
  GITHUB_OIDC_AGENT_RUNNER_REF?: string;
  GITHUB_DISPATCH_TOKEN?: string;
  GITHUB_WEBHOOK_SECRET?: string;
  GITHUB_AUTO_RECOVERY_MAX_ATTEMPTS?: string;
  GITHUB_ACTIONS_DISPATCH_ENABLED?: string;
  GITHUB_REPOSITORY?: string;
  GITHUB_WORKFLOW_FILE?: string;
  OPS_ALERT_URL?: string;
  OPS_ALERT_AUTH?: string;
  D1_REST_API_TOKEN?: string;
  CLOUDFLARE_ACCOUNT_ID?: string;
  D1_DATABASE_ID?: string;
  D1_DATABASE_LIMIT_BYTES?: string;
  R2_ACCESS_KEY_ID?: string;
  R2_SECRET_ACCESS_KEY?: string;
  R2_EVIDENCE_BUCKET?: string;
  GHOST_ADMIN_ORIGIN?: string;
  GHOST_ADMIN_KEY?: string;
  GHOST_PUBLIC_ORIGIN?: string;
  DEPLOYED_COMMIT?: string;
}

export type MutationRole = "capture" | "engine" | "operator";

export interface MutationKeyRecord {
  secret: string;
  role: MutationRole;
  sourceIds?: string[];
  registeredAgent?: boolean;
}

export interface MutationIdentity extends MutationKeyRecord {
  agentId: string;
  authMethod: "hmac" | "github_oidc";
  workflowRef?: string;
  jobWorkflowRef?: string;
  githubRunId?: string;
  capabilities?: string[];
  registeredAgentId?: string;
}
