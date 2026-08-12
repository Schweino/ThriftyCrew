import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import { gunzipSync, gzipSync } from "node:zlib";

const MAGIC = Buffer.from("TCJ1", "ascii");

export function encryptCaptureJournalEnvelope(plain: Uint8Array, key: Uint8Array): Uint8Array {
  if (key.byteLength !== 32) throw new Error("capture journal encryption key must contain 32 bytes");
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  cipher.setAAD(MAGIC);
  const ciphertext = Buffer.concat([cipher.update(gzipSync(plain, { level: 9 })), cipher.final()]);
  return Buffer.concat([MAGIC, iv, cipher.getAuthTag(), ciphertext]);
}

export function decryptCaptureJournalEnvelope(envelope: Uint8Array, key: Uint8Array): Uint8Array {
  if (key.byteLength !== 32) throw new Error("capture journal encryption key must contain 32 bytes");
  const bytes = Buffer.from(envelope);
  if (bytes.byteLength < 4 + 12 + 16 || !bytes.subarray(0, 4).equals(MAGIC)) throw new Error("capture journal checkpoint envelope is invalid");
  const decipher = createDecipheriv("aes-256-gcm", key, bytes.subarray(4, 16));
  decipher.setAAD(MAGIC);
  decipher.setAuthTag(bytes.subarray(16, 32));
  return gunzipSync(Buffer.concat([decipher.update(bytes.subarray(32)), decipher.final()]));
}
