import { AwsClient } from "aws4fetch";
import type { WorkerEnv } from "./env";

export interface DirectEvidenceUploadInput {
  uploadSessionId: string;
  objectKey: string;
  evidenceId: string;
  kind: string;
  contentType: string;
  sha256: string;
  contentMd5: string;
  expiresSeconds?: number;
}

function objectUrl(env: WorkerEnv, objectKey: string): URL {
  if (!env.CLOUDFLARE_ACCOUNT_ID) throw new Error("CLOUDFLARE_ACCOUNT_ID is required for direct R2 upload");
  const bucket = env.R2_EVIDENCE_BUCKET ?? "tc-grocery-v3-evidence";
  const encodedKey = objectKey.split("/").map(encodeURIComponent).join("/");
  return new URL(`https://${env.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com/${bucket}/${encodedKey}`);
}

export async function createDirectObjectDownload(env: WorkerEnv, objectKey: string, expiresSeconds = 300): Promise<{ url: string; expiresIn: number }> {
  if (!env.R2_ACCESS_KEY_ID || !env.R2_SECRET_ACCESS_KEY) throw new Error("direct R2 download credentials are unavailable");
  const expiresIn = Math.min(900, Math.max(60, expiresSeconds));
  const url = objectUrl(env, objectKey);
  url.searchParams.set("X-Amz-Expires", String(expiresIn));
  const signer = new AwsClient({
    accessKeyId: env.R2_ACCESS_KEY_ID,
    secretAccessKey: env.R2_SECRET_ACCESS_KEY,
    service: "s3",
    region: "auto",
  });
  const signed = await signer.sign(new Request(url, { method: "GET" }), { aws: { signQuery: true } });
  return { url: signed.url, expiresIn };
}

export async function createDirectEvidenceUpload(env: WorkerEnv, input: DirectEvidenceUploadInput): Promise<{ url: string; headers: Record<string, string>; expiresIn: number }> {
  if (!env.R2_ACCESS_KEY_ID || !env.R2_SECRET_ACCESS_KEY) throw new Error("direct R2 upload credentials are unavailable");
  const expiresIn = Math.min(900, Math.max(60, input.expiresSeconds ?? 900));
  const url = objectUrl(env, input.objectKey);
  url.searchParams.set("X-Amz-Expires", String(expiresIn));
  const headers = {
    "content-type": input.contentType,
    "content-md5": input.contentMd5,
    "x-amz-meta-sha256": input.sha256,
    "x-amz-meta-kind": input.kind,
    "x-amz-meta-evidenceid": input.evidenceId,
    "x-amz-meta-uploadsessionid": input.uploadSessionId,
  };
  const signer = new AwsClient({
    accessKeyId: env.R2_ACCESS_KEY_ID,
    secretAccessKey: env.R2_SECRET_ACCESS_KEY,
    service: "s3",
    region: "auto",
  });
  const signed = await signer.sign(new Request(url, { method: "PUT", headers }), { aws: { signQuery: true } });
  return { url: signed.url, headers, expiresIn };
}
