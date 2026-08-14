export function releasePayloadObjectKey(releaseId: string, kind: string, contentHash: string): string {
  if (!/^[a-zA-Z0-9_-]+$/.test(releaseId)) throw new Error("release payload object key requires a safe release id");
  if (!/^[a-z_]+$/.test(kind)) throw new Error("release payload object key requires a safe payload kind");
  if (!/^[a-f0-9]{64}$/.test(contentHash)) throw new Error("release payload object key requires a SHA-256 content hash");
  return `release-payloads/v2/release=${releaseId}/kind=${kind}/prefix=${contentHash.slice(0, 2)}/${contentHash}.json`;
}
