export interface JournalQueueJob {
  id: string; directory: string; sourceId: string; status: string; enqueuedAt: string; nextAttemptAt: string; manifestJson: string;
}
export function captureJournalPath(environment?: NodeJS.ProcessEnv): string;
export function upsertQueueJournalJob(job: JournalQueueJob, file?: string): void;
export function queueJournalJobs(file?: string): JournalQueueJob[];
export function acquireQueueJournalLease(jobId: string, owner: string, now: Date, leaseMs?: number, file?: string): boolean;
export function releaseQueueJournalLease(jobId: string, owner: string, file?: string): void;
export function upsertSessionJournal(directory: string, draft: { sessionId: string; store: string; chunks?: Array<{ id: string; file: string; sha256: string; createdAt: string }> }, file?: string): void;
export function readSessionJournal<T>(directory: string, file?: string): T | null;
export function readPlannerJournal(namespace: string, file?: string): Record<string, Record<string, unknown>>;
export function replacePlannerJournal(namespace: string, values: Record<string, Record<string, unknown>>, observedAt: string, file?: string): void;
export function serializeCaptureJournal(file?: string): Uint8Array;
export function closeCaptureJournals(): void;
export function acquireControllerLane(store: string, owner: string, now?: Date, ttlMs?: number, environment?: NodeJS.ProcessEnv): { acquired: boolean; active?: number; reason?: string };
export function releaseLaneLease(store: string, owner: string, environment?: NodeJS.ProcessEnv): void;
export function writeLaneState(store: string, state: Record<string, unknown>, environment?: NodeJS.ProcessEnv): void;
