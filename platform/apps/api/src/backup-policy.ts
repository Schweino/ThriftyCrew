export const D1_EXPORT_POLL_STEP_CONFIG = {
  retries: {
    limit: 60,
    delay: "15 seconds",
    backoff: "constant",
  },
  timeout: "2 minutes",
} as const;
