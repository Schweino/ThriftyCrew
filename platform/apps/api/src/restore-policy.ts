// Paid Workers gives each normalization step enough CPU for an R2-native 5 MiB source window.
// Parts extend to the next SQL line boundary. Only partitions that remove oversized payload rows
// need padding, and that padding is emitted as bounded SQL no-ops rather than one parser-sized run.
export const RESTORE_SOURCE_PART_BYTES = 5 * 1024 * 1024;
export const RESTORE_MULTIPART_PART_BYTES = 5 * 1024 * 1024;
const RESTORE_PADDING_STATEMENT_BYTES = 32 * 1024;
const RESTORE_PADDING_PREFIX = new TextEncoder().encode("--");
const RESTORE_PADDING_SUFFIX = new TextEncoder().encode("\nSELECT 1;\n");

if (RESTORE_MULTIPART_PART_BYTES < 5 * 1024 * 1024) {
  throw new Error("R2 multipart parts must be at least 5 MiB except for the final part");
}

export function padRestoreMultipartPart(
  output: Uint8Array<ArrayBufferLike>,
  targetBytes = RESTORE_MULTIPART_PART_BYTES,
): Uint8Array<ArrayBuffer> {
  if (output.byteLength >= targetBytes) return Uint8Array.from(output);
  const needsSeparator = output.byteLength > 0 && output.at(-1) !== 0x0a;
  const prefixBytes = output.byteLength + (needsSeparator ? 1 : 0);
  const minimumStatementBytes = RESTORE_PADDING_PREFIX.byteLength + RESTORE_PADDING_SUFFIX.byteLength;
  const statementSizes: number[] = [];
  let remaining = targetBytes - prefixBytes;
  while (remaining > 0) {
    const size = Math.min(RESTORE_PADDING_STATEMENT_BYTES, Math.max(minimumStatementBytes, remaining));
    statementSizes.push(size);
    remaining -= size;
  }
  const padded = new Uint8Array(new ArrayBuffer(prefixBytes + statementSizes.reduce((sum, size) => sum + size, 0)));
  padded.set(output);
  if (needsSeparator) padded[output.byteLength] = 0x0a;
  let offset = prefixBytes;
  for (const size of statementSizes) {
    padded.set(RESTORE_PADDING_PREFIX, offset);
    padded.fill(0x20, offset + RESTORE_PADDING_PREFIX.byteLength, offset + size - RESTORE_PADDING_SUFFIX.byteLength);
    padded.set(RESTORE_PADDING_SUFFIX, offset + size - RESTORE_PADDING_SUFFIX.byteLength);
    offset += size;
  }
  return padded;
}
