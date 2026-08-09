import type { Entitlement } from "@thriftycrew/entitlements";

export function memberStatusHtml(entitlement: Entitlement): string {
  const label = entitlement.state.replace("_", " ");
  const access = entitlement.mayUseProtectedTools ? "Paid tools are available." : "Paid tools are locked.";
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>Member status | Thrifty Crew</title>
<style>html{color-scheme:light}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4efe4;color:#173f35;font:16px/1.5 ui-sans-serif,system-ui,sans-serif}.card{width:min(31rem,calc(100% - 2rem));box-sizing:border-box;padding:2rem;border:1px solid #c7bda8;border-radius:1.25rem;background:#fff;box-shadow:0 1rem 3rem #173f3518}.eyebrow{margin:0 0 .5rem;font-size:.75rem;font-weight:800;letter-spacing:.14em;text-transform:uppercase}.state{margin:0;font:800 clamp(2rem,9vw,3.5rem)/1.05 ui-serif,Georgia,serif;text-transform:capitalize}.access{margin:1rem 0 0;color:#47675f}.back{display:inline-block;margin-top:1.5rem;color:#173f35;font-weight:700}</style></head>
<body><main class="card"><p class="eyebrow">Member access</p><h1 class="state">${label}</h1><p class="access">${access}</p><a class="back" href="/omaha-grocery-prices/">Back to the price board</a></main></body></html>`;
}
