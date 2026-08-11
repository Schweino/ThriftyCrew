export const MAX_ENCODED_EVIDENCE_BYTES = 20 * 1024 * 1024;
export const MAX_DECODED_EVIDENCE_BYTES = 80 * 1024 * 1024;

export async function decodeEvidenceUpload(
  encoded: Uint8Array,
  contentEncoding: string | undefined,
  declaredDecodedLength: string | undefined,
): Promise<Uint8Array> {
  if (encoded.byteLength > MAX_ENCODED_EVIDENCE_BYTES) throw new Error("evidence object exceeds 20 MiB encoded");
  const encoding = contentEncoding?.trim().toLowerCase() || "identity";
  if (encoding === "identity") return encoded;
  if (encoding !== "gzip") throw new Error(`unsupported evidence content encoding: ${encoding}`);
  if (!declaredDecodedLength || !/^\d+$/.test(declaredDecodedLength)) throw new Error("gzip evidence requires x-uncompressed-length");
  const expectedLength = Number(declaredDecodedLength);
  if (!Number.isSafeInteger(expectedLength) || expectedLength < 1 || expectedLength > MAX_DECODED_EVIDENCE_BYTES) {
    throw new Error("evidence object exceeds 80 MiB decoded");
  }
  let decoded: Uint8Array;
  try {
    const payload = new ArrayBuffer(encoded.byteLength);
    new Uint8Array(payload).set(encoded);
    const stream = new Blob([payload]).stream().pipeThrough(new DecompressionStream("gzip"));
    decoded = new Uint8Array(await new Response(stream).arrayBuffer());
  } catch {
    throw new Error("invalid gzip evidence body");
  }
  if (decoded.byteLength !== expectedLength) throw new Error("gzip evidence decoded length does not match declaration");
  if (decoded.byteLength > MAX_DECODED_EVIDENCE_BYTES) throw new Error("evidence object exceeds 80 MiB decoded");
  return decoded;
}
