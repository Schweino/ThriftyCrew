import { ingestDirectCapture, type CaptureEvidenceInput, MutationClient } from "@thriftycrew/daily/client";
import {
  defaultCaptureQueueRoot,
  drainCaptureQueue,
  markCaptureEvidenceUploaded,
  PermanentCaptureError,
  readCaptureQueueEvidence,
} from "./capture-queue";

export function localCaptureMutationClient(environment: NodeJS.ProcessEnv = process.env): MutationClient {
  const secret = environment.TC_LOCAL_MUTATION_SECRET;
  if (!secret) throw new Error("TC_LOCAL_MUTATION_SECRET is required by the persistent capture controller");
  return new MutationClient({
    origin: environment.TC_API_ORIGIN ?? "https://tc-grocery-public.curly-unit-51a6.workers.dev",
    agentId: environment.TC_AGENT_ID ?? "pc-browser-capture",
    secret,
  });
}

export async function drainBrowserCaptureQueue(
  client = localCaptureMutationClient(),
  root = defaultCaptureQueueRoot(),
  maxJobs = Number(process.env.TC_CAPTURE_QUEUE_MAX_JOBS_PER_DRAIN ?? 4),
) {
  if (!Number.isInteger(maxJobs) || maxJobs < 1 || maxJobs > 20) throw new Error("capture queue maximum must be an integer from 1 through 20");
  return drainCaptureQueue(root, async (job) => {
    const additionalEvidence: CaptureEvidenceInput[] = await Promise.all(job.evidencePaths.map(async (evidence) => {
      const source = await readCaptureQueueEvidence(job, evidence);
      const body = evidence.kind === "manifest"
        ? new TextEncoder().encode(JSON.stringify(JSON.parse(new TextDecoder().decode(source).replace(/^\uFEFF/, ""))))
        : source;
      return { body, kind: evidence.kind, contentType: evidence.contentType };
    }));
    const ingestion = await ingestDirectCapture(client, job.artifact, job.artifactBody, additionalEvidence, {
      promote: false,
      directEvidenceUpload: true,
      ...(job.manifest.browserEvidenceAttestation ? { browserEvidenceAttestation: job.manifest.browserEvidenceAttestation } : {}),
      uploadedEvidenceSha256: new Set((job.manifest.uploadedEvidence ?? []).map((entry) => entry.sha256)),
      onEvidenceUploaded: async ({ sha256, evidenceId }) => markCaptureEvidenceUploaded(job, { sha256, evidenceId }),
    });
    if (!ingestion.ok) {
      const seal = ingestion.seal as Record<string, unknown> | undefined;
      throw new PermanentCaptureError(`capture batch ${String(ingestion.batchId)} was rejected (${String(seal?.status ?? ingestion.status ?? "unknown")}): ${String(seal?.error ?? "capture guards failed")}`);
    }
    return ingestion;
  }, { maxJobs });
}
