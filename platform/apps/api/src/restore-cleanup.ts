export function isMissingMultipartUploadError(error: unknown): boolean {
  return error instanceof Error && error.message.toLowerCase().includes("specified multipart upload does not exist");
}
