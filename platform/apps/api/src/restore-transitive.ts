import { digestHex } from "@thriftycrew/domain";

export interface ReleaseRecoveryRoot {
  release_id: string;
  root_hash: string;
  object_key: string;
  node_count?: number;
}

export interface ReleaseManifest {
  version: number;
  releaseId: string;
  nodes: Array<{ kind: string; key: string; contentHash: string }>;
}

function releaseNodeKey(kind: string, contentHash: string): string {
  return `release-nodes/schema=1/kind=${kind}/prefix=${contentHash.slice(0, 2)}/${contentHash}.json`;
}

export async function verifyHashedObject(bucket: R2Bucket, key: string, expectedHash: string, expectedBytes?: number): Promise<Uint8Array> {
  const object = await bucket.get(key);
  if (!object) throw new Error(`immutable recovery object is missing: ${key}`);
  const bytes = new Uint8Array(await object.arrayBuffer());
  if (expectedBytes !== undefined && bytes.byteLength !== expectedBytes) throw new Error(`immutable recovery object size failed: ${key}`);
  if (await digestHex(bytes) !== expectedHash) throw new Error(`immutable recovery object content hash failed: ${key}`);
  return bytes;
}

export async function readVerifiedReleaseManifest(env: { ARCHIVE: R2Bucket }, root: ReleaseRecoveryRoot): Promise<ReleaseManifest> {
  const manifestBytes = await verifyHashedObject(env.ARCHIVE, root.object_key, root.root_hash);
  const manifest = JSON.parse(new TextDecoder().decode(manifestBytes)) as ReleaseManifest;
  if (manifest.version !== 1 || manifest.releaseId !== root.release_id || !Array.isArray(manifest.nodes)) throw new Error(`release manifest contract failed: ${root.release_id}`);
  if (root.node_count !== undefined && manifest.nodes.length !== root.node_count) throw new Error(`release manifest node count failed: ${root.release_id}`);
  return manifest;
}

export async function verifyReleaseNodeChunk(env: { ARCHIVE: R2Bucket }, releaseId: string, nodes: ReleaseManifest["nodes"]): Promise<number> {
  await Promise.all(nodes.map((node) => {
    if (!/^[a-f0-9]{64}$/.test(node.contentHash) || !node.kind) throw new Error(`release node identity failed: ${releaseId}`);
    return verifyHashedObject(env.ARCHIVE, releaseNodeKey(node.kind, node.contentHash), node.contentHash);
  }));
  return nodes.length;
}

export async function verifyReleaseGraphTransitive(env: { ARCHIVE: R2Bucket }, root: ReleaseRecoveryRoot): Promise<number> {
  const manifest = await readVerifiedReleaseManifest(env, root);
  for (let offset = 0; offset < manifest.nodes.length; offset += 40) {
    await verifyReleaseNodeChunk(env, root.release_id, manifest.nodes.slice(offset, offset + 40));
  }
  return manifest.nodes.length + 1;
}
