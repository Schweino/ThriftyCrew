export const RESTORE_SOURCE_PART_BYTES = 4 * 1024 * 1024;
export const RESTORE_MULTIPART_PART_BYTES = 5 * 1024 * 1024;

if (RESTORE_MULTIPART_PART_BYTES < 5 * 1024 * 1024) {
  throw new Error("R2 multipart parts must be at least 5 MiB except for the final part");
}
