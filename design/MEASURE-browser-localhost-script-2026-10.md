# Can a store page load a script from localhost? (2026-10-02)

design/PLAN-browser-refresh-hardening-2026-10-02.md W3 step 1. The question: for each of the four browser stores, will
the page load `<script src="http://localhost:...">`, so the capture sink could serve the committed scripts and the
model would never retype them (step 2a)?

## Knowledge consulted

- The plan's W3 section, and `skills/mcp-craft/intelligence-budget.md` section 6 (scripted orchestration: keep
  intermediate data below the model boundary), which is why step 2a was worth measuring.
- `grocery/capture-sink.ps1` header (why a form POST and not fetch: walmart.com's connect-src) and the task file's
  2026-10-02 note (a form targeting an iframe failed on all four stores, silently on three).
- searched "localhost script load store page csp", nothing further applicable.

## Bar, written before the run (copied from the plan)

The loader route (step 2a) is worth building for any store where a localhost script loads.

## Method (the harness, as run)

1. Response CSP: `curl -s -L -A <Chrome UA> -D <headers>` of the four store pages below, reading the
   `Content-Security-Policy` header and any `<meta http-equiv="Content-Security-Policy">` in the body.
2. Load test, in Brad's Chrome (Chrome/154.0.0.0) through the Claude in Chrome tools, one tab: a probe file
   `probe.js` (one line: `window.__tcProbeLoaded = 'loaded-from-localhost';`) served by
   `python -m http.server 8793 --bind 127.0.0.1` from a scratch directory; on each store page,
   `document.createElement('script')` with `src` = `http://127.0.0.1:8793/probe.js?<tag>` and then
   `http://localhost:8793/probe.js?<tag>` (Walmart: localhost only), appended to `document.head`, waiting up to 8 s
   for onload/onerror, with a `securitypolicyviolation` listener on the document. The server's request log is the
   second witness: a request that never reaches it was stopped in the browser.
3. Control: `curl` of both URLs from the shell answered 200 and appear in the server log, so the server was up.

## Results, one row per store

| store | page | CSP that governs scripts | script result | reached the server | CSP violation event | verdict |
|---|---|---|---|---|---|---|
| Walmart | https://www.walmart.com/ | meta tag: `script-src 'self' 'strict-dynamic' 'wasm-unsafe-eval'` + allow-list + nonce; no localhost | no load (no onload, no onerror in 8 s; twice) | no | none | BLOCKED |
| Aldi | https://www.aldi.us/store/aldi/storefront | none (header is `frame-ancestors` only; no meta) | onerror, both hosts | no | none | BLOCKED |
| Sam's Club | https://www.samsclub.com/ | none (no CSP header, no meta) | no load in 8 s, both hosts | no | none | BLOCKED |
| Fareway | https://shop.fareway.com/store/fareway-meat-grocery/storefront | none (header is `frame-ancestors` only; no meta) | no load in 8 s, both hosts | no | none | BLOCKED |

Loads: **0 of 4**. Server requests from the browser: **0** (its log holds only the two shell control requests).

## Reading

CSP is not what stops it. Three of the four pages declare no script policy at all, and no page fired a violation
event, yet no request left the browser on any of them. That shape is Chrome's Local Network Access: a public HTTPS
page's subresource request to a loopback address is held for a per-site permission, or refused, before it is sent.
No permission prompt was visible in the page screenshots, and none was granted: granting one is a browser security
setting, which is Brad's to change, not the agent's. It also explains the 2026-10-02 iframe failures (silent on Aldi,
Sam's and Fareway), while a top-level form POST, which is a navigation, still lands.

## Verdict against the bar

**NOT MET on all four stores.** Step 2a (the sink serving the scripts) is not built. Every store takes step 2b,
which is the committed runner from W4 (`tcStart`/`tcWait`, the finish functions and the brief templates): the paste
stays, the turns drop.

The one way 2a could still work is if Brad allowed "local network access" for the four store sites in his Chrome.
That is his decision, recorded as an open question in the plan, not assumed here.

## Re-run

Repeat step 2 above with a fresh scratch directory; the probe file and the server command are the whole harness.
