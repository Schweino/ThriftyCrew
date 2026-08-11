export const D1_EXPORT_POLL_STEP_CONFIG = {
  retries: {
    limit: 240,
    delay: "1 minute",
    backoff: "constant",
  },
  timeout: "2 minutes",
} as const;

export function d1ExportPollPayload(bookmark: string): { output_format: "polling"; current_bookmark: string } {
  return { output_format: "polling", current_bookmark: bookmark };
}

export function d1ExportTerminalError(result: { status?: string; error?: string }): string | null {
  return result.status === "error" && typeof result.error === "string" && result.error.trim().length > 0
    ? result.error.trim()
    : null;
}
