// Paid Workers gives each normalization step enough CPU for a 4.5 MiB source window. The boundary
// search is capped at 512 KiB, so every part still fits R2's 5 MiB multipart limit while padding can
// never exceed 512 KiB. D1 counts that whitespace toward the following SQL statement's length.
export const RESTORE_SOURCE_PART_BYTES = (9 * 1024 * 1024) / 2;
export const RESTORE_MULTIPART_PART_BYTES = 5 * 1024 * 1024;

if (RESTORE_MULTIPART_PART_BYTES < 5 * 1024 * 1024) {
  throw new Error("R2 multipart parts must be at least 5 MiB except for the final part");
}

export function padRestoreMultipartPart(
  output: Uint8Array<ArrayBufferLike>,
  targetBytes = RESTORE_MULTIPART_PART_BYTES,
): Uint8Array<ArrayBuffer> {
  const needsSeparator = output.byteLength > 0 && output.at(-1) !== 0x0a;
  const requiredBytes = output.byteLength + (needsSeparator ? 1 : 0);
  if (requiredBytes > targetBytes) {
    throw new Error("normalized multipart part exceeds the fixed R2 part size");
  }

  const padded = new Uint8Array(new ArrayBuffer(targetBytes));
  padded.fill(0x20);
  padded.set(output);
  if (needsSeparator) padded[output.byteLength] = 0x0a;
  return padded;
}
