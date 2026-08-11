import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import { digestHex } from "@thriftycrew/domain";
import type { MutationKeyRecord, WorkerEnv } from "./env";
import { raiseOperationalAlert, resolveOperationalAlert } from "./operations";

interface CaptureValidationPayload { batchId: string }

function operatorIdentity(env: WorkerEnv): { agentId: string; secret: string } {
  const keys = JSON.parse(env.MUTATION_KEYS ?? "{}") as Record<string, MutationKeyRecord>;
  const selected = Object.entries(keys).find(([, record]) => record.role === "operator");
  if (!selected) throw new Error("capture validation workflow requires an operator mutation key");
  return { agentId: selected[0], secret: selected[1].secret };
}

async function hmacHex(secret: string, value: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(value));
  return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export class CaptureValidationWorkflow extends WorkflowEntrypoint<WorkerEnv, CaptureValidationPayload> {
  override async run(event: WorkflowEvent<CaptureValidationPayload>, step: WorkflowStep): Promise<void> {
    const batchId = event.payload.batchId;
    try {
      await step.do("validate and seal immutable capture", { retries: { limit: 5, delay: "10 seconds", backoff: "exponential" }, timeout: "5 minutes" }, async () => {
      const job = await this.env.DB.prepare(
        "SELECT seal_json, status FROM capture_validation_jobs WHERE batch_id = ?1",
      ).bind(batchId).first<{ seal_json: string; status: string }>();
      if (!job) throw new Error(`capture validation job ${batchId} is missing`);
      if (job.status === "completed") return;
      await this.env.DB.prepare(
        `UPDATE capture_validation_jobs SET status = 'running', attempts = attempts + 1,
          started_at = COALESCE(started_at, CURRENT_TIMESTAMP), error = NULL WHERE batch_id = ?1`,
      ).bind(batchId).run();
      const identity = operatorIdentity(this.env);
      const pathname = `/internal/capture-batches/${encodeURIComponent(batchId)}/seal`;
      const body = new TextEncoder().encode(job.seal_json);
      const timestamp = new Date().toISOString();
      const nonce = `workflow_${crypto.randomUUID()}`;
      const canonical = [timestamp, nonce, "POST", pathname, await digestHex(body)].join("\n");
      const response = await fetch(new URL(pathname, this.env.PUBLIC_ORIGIN), {
        method: "POST",
        headers: {
          "content-type": "application/json", "x-tc-agent": identity.agentId,
          "x-tc-timestamp": timestamp, "x-tc-nonce": nonce,
          "x-tc-signature": await hmacHex(identity.secret, canonical),
          "x-tc-validation-workflow": event.instanceId,
        },
        body,
      });
      const result = await response.json().catch(() => ({})) as Record<string, unknown>;
      if (response.status >= 500) throw new Error(`capture validation returned ${response.status}: ${String(result.error ?? "internal error")}`);
      if (![200, 409, 422].includes(response.status)) throw new Error(`capture validation returned unexpected ${response.status}: ${String(result.error ?? "unknown")}`);
      const resultStatus = String(result.status ?? (response.status === 422 ? "rejected" : "validated"));
      await this.env.DB.prepare(
        `UPDATE capture_validation_jobs SET status = 'completed', result_status = ?2, error = ?3,
          completed_at = CURRENT_TIMESTAMP WHERE batch_id = ?1`,
      ).bind(batchId, resultStatus, typeof result.error === "string" ? result.error.slice(0, 2000) : null).run();
      });
      await resolveOperationalAlert(this.env, `capture-validation:${batchId}`, { batchId, workflowInstanceId: event.instanceId }, { recoveryTitle: `Browser capture validation recovered for ${batchId}` });
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      await this.env.DB.prepare(
        `UPDATE capture_validation_jobs SET status = 'failed', error = ?2, completed_at = CURRENT_TIMESTAMP WHERE batch_id = ?1`,
      ).bind(batchId, detail.slice(0, 2000)).run();
      await raiseOperationalAlert(this.env, `capture-validation:${batchId}`, `Browser capture validation failed for ${batchId}`, { batchId, workflowInstanceId: event.instanceId, detail });
      throw error;
    }
  }
}
