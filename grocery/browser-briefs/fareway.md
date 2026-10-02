<!-- grocery\browser-briefs\fareway.md: the Fareway store agent's own steps. Joined after _common.md by
     grocery\fill-browser-brief.ps1. design\PLAN-browser-refresh-hardening-2026-10-02.md W4. -->
## The store rule

The board's Fareway is retailerLocation **531573** (Omaha), **In-Store**. A fresh session sits plausibly on Des Moines
(513473), and on 2026-09-19 it sat on Pickup at the right store; pickup prices are not shelf prices.
`farewayIdentity()` reads both from the page's Apollo cache and throws on either. If the mode is wrong, switch it to
In-Store in the page's own picker and run Step 2 again. The sweep itself stops (`aborted`) if any row is read off
531573, and `select-fareway-shop` refuses a capture with a row scoped to another term, so never strip, merge or
hand-build lines.

## Step 1: open the page

Navigate tab {{TABID}} to `https://shop.fareway.com/store/fareway-meat-grocery/s?k={{FIRST_TERM_URL}}`. Read the files
`{{GROCERY}}\pull-agent-lib.js`, `{{GROCERY}}\pull-fareway-instore.js` and
`{{GROCERY}}\pull-fareway-shop.js` with the Read tool.

## Step 2: inject, assert, start (ONE javascript_tool call)

Paste each file on the lines between its markers, starting on the line after the BEGIN marker, and send:

```js
(function __tcInject() {
  const __tcMem = {};
  const localStorage = {
    getItem: k => (Object.prototype.hasOwnProperty.call(__tcMem, k) ? __tcMem[k] : null),
    setItem: (k, v) => { __tcMem[k] = String(v); },
    removeItem: k => { delete __tcMem[k]; }
  };
/*TC-A-BEGIN*/
<<< paste pull-agent-lib.js here, exactly >>>
/*TC-A-END*/
{
/*TC-B-BEGIN*/
<<< paste pull-fareway-instore.js here, exactly >>>
/*TC-B-END*/
}
{
/*TC-C-BEGIN*/
<<< paste pull-fareway-shop.js here, exactly >>>
/*TC-C-END*/
}
  const src = __tcInject.toString();
  const seg = (a, b) => {
    const i = src.indexOf('/*TC-' + a), j = src.indexOf('/*TC-' + b);
    return (i < 0 || j < 0) ? '' : src.slice(src.indexOf('*/', i) + 2, j).replace(/^\n+|\n+$/g, '');
  };
  const got = { lib: seg('A-BEGIN', 'A-END').length, instore: seg('B-BEGIN', 'B-END').length, shop: seg('C-BEGIN', 'C-END').length };
  const want = { lib: {{LEN:pull-agent-lib.js}}, instore: {{LEN:pull-fareway-instore.js}}, shop: {{LEN:pull-fareway-shop.js}} };
  if (got.lib !== want.lib || got.instore !== want.instore || got.shop !== want.shop) {
    return { refused: 'PASTE LENGTH MISMATCH: nothing was started. Re-read the file and paste it exactly.', got, want };
  }
  if (typeof window.farewaySweep !== 'function') {
    return { refused: 'farewaySweep is missing: the main checkout is stale. Capture NOTHING for Fareway and report it.' };
  }
  const identity = window.farewayIdentity();
  const TERMS = {{TERMS}};
  const COMMS = {{COMMS}};
  return { got, want, identity, terms: TERMS.length,
           started: tcStart('fareway', () => window.farewaySweep(TERMS, COMMS, { loc: '531573' }),
             () => { const s = window.__fwSweep; return s ? { i: s.i, n: s.n, lines: s.lines.length, errors: s.errors.length, aborted: s.aborted } : null; }) };
})()
```

A `refused` answer means fix the paste (or report the stale checkout) and send Step 2 again. A thrown REFUSING error
means the store or mode is wrong: see the store rule.

## Step 3: wait

`await window.tcWait(40000)`, repeated until `done` is true (at most 45 times). Fareway takes about 18 s a term; each
wait's `progress` shows `i` of `n`.

## Step 4: post (ONE javascript_tool call, the last in this tab)

```js
window.farewayFinish('{{SINK}}')
```

It posts the sweep's JSON lines unaltered, including the lines read before an abort, and returns `errors` (terms that
never settled) and `aborted`. Then read the tab's text: the sink's reply is `ok <chars> <lines> chars=AGREE (<n>)`.
Anything but AGREE is an open item, never a pass.

## Report

```
FAREWAY {{DATE}}: requested {{N_TERMS}} | with lines <summary.lines> | errors <sent.errors> (<terms>) | aborted "<sent.aborted>"
injected lib <got.lib>/<want.lib> instore <got.instore>/<want.instore> shop <got.shop>/<want.shop> | identity <identity>
posted {{SINK}} chars <sent.chars> lines <sent.lines> | sink reply "<reply>"
tool calls <n> | open items <list, or none>
```
