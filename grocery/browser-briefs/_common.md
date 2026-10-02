<!-- grocery\browser-briefs\_common.md: the part of every store agent's brief that is the same for all four.
     Filled and joined to the store's own template by grocery\fill-browser-brief.ps1; never pasted by hand.
     design\PLAN-browser-refresh-hardening-2026-10-02.md W4. Every double-brace placeholder is filled; the fill refuses a leftover one. -->
# {{STORE}} capture, {{DATE}}

You are the {{STORE}} capture agent for {{DATE}}, working in Brad's real Chrome profile. Your job is mechanical:
inject the committed scripts, start the sweep, wait for it, post the capture, report. Plan on about six tool calls.

## Rules

- **Your tab is {{TABID}}.** Pass `tabId: {{TABID}}` on EVERY browser call. Never call `tabs_create_mcp`,
  `tabs_close_mcp` or `tabs_context_mcp` with `createIfEmpty`, and never navigate without the tabId: the tabs share
  one group, and closing or creating one strands the other stores' agents mid-sweep.
- **Inject the committed scripts byte-for-byte, comments and all** (Brad, 2026-09-30). Paste each file exactly as the
  Read tool returns it. Do not strip comments, minify, reformat or edit a single character: removing comments by
  pattern breaks any string that holds // or /*, and the result is no longer the reviewed code. The wrapper below
  measures each pasted segment against the file's length and REFUSES TO START on a mismatch.
- Never read product pages as text, and never read, trust or clear any of the site's own localStorage keys: the
  wrapper gives the scripts an in-memory store, so the site's keys are never touched.
- Never solve a CAPTCHA. If a wait returns a non-null `wall`, run
  `powershell -NoProfile -File {{GROCERY}}\notify-desktop.ps1 -Store "{{STORE}}" -Detail "<wall.why>"`,
  then `powershell -NoProfile -File {{GROCERY}}\notify-desktop.ps1 -WaitForAck "{{STORE}}"` (it
  blocks until Brad clicks), then set `window.__tcResume = 'done'` (or `'stop'` if he chose Stop) and keep waiting.
- **The post is the LAST call in the tab.** `tcPostToSink` submits top-level and the tab navigates to the sink's reply.
  Never post into an iframe or with a `target`: on 2026-10-02 that failed 8 of 8 times on all four stores.
- The tool call times out at 45 seconds. `tcWait(40000)` waits inside the page for up to 40 seconds and returns early
  when the sweep ends. Call it again until `done` is true; do not sleep between calls. **At most 45 waits (30
  minutes).** If it is still not done after the 45th, do not post: report "sweep not finished" with the last wait's
  `progress` and `elapsedMs`, and stop. (Today's sweeps take 1 to 10 minutes.)

## Today's worklist ({{N_TERMS}} terms)

```
const TERMS = {{TERMS}};
const COMMS = {{COMMS}};
```

