interface PublicWorkerEnv {
  CONTROL: Fetcher;
  APP_ENV: string;
  DEPLOYED_COMMIT?: string;
}

function permittedHost(url: URL): boolean {
  return url.hostname === "www.thriftycrew.com"
    || url.hostname.endsWith(".tc-grocery-public.workers.dev")
    || url.hostname === "tc-grocery-public.curly-unit-51a6.workers.dev";
}

export default {
  async fetch(request: Request, env: PublicWorkerEnv): Promise<Response> {
    const url = new URL(request.url);
    if (!permittedHost(url)) return Response.json({ ok: false, error: "unknown host" }, { status: 421 });
    const response = await env.CONTROL.fetch(request);
    const headers = new Headers(response.headers);
    headers.set("x-content-type-options", "nosniff");
    headers.set("referrer-policy", "strict-origin-when-cross-origin");
    return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
  },
} satisfies ExportedHandler<PublicWorkerEnv>;
