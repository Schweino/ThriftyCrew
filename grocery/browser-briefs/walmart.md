<!-- grocery\browser-briefs\walmart.md: the Walmart store agent's own steps. Joined after _common.md by
     grocery\fill-browser-brief.ps1. design\PLAN-browser-refresh-hardening-2026-10-02.md W4. -->
## The store rule

The board's Walmart is storeId **5361**, Omaha L St Supercenter, 68137 (Brad's ruling 2026-08-28,
`stores.json` -> Walmart -> `store_identity`). The id is the discriminator: 3153 is an Omaha address too.
`walmartIdentity()` throws on any other store, and every search response is re-read, so a term read at another store
settles UNUSABLE. If it refuses, SWITCH THE STORE to L St in the page's own store picker (yours to do, Brad
2026-08-28) and run Step 1 again.

## Step 1: open the page

Navigate tab {{TABID}} to `https://www.walmart.com/`. Read the files `{{GROCERY}}\pull-agent-lib.js`
and `{{GROCERY}}\pull-walmart-instore.js` with the Read tool.

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
<<< paste pull-walmart-instore.js here, exactly >>>
/*TC-B-END*/
}
  const src = __tcInject.toString();
  const seg = (a, b) => {
    const i = src.indexOf('/*TC-' + a), j = src.indexOf('/*TC-' + b);
    return (i < 0 || j < 0) ? '' : src.slice(src.indexOf('*/', i) + 2, j).replace(/^\n+|\n+$/g, '');
  };
  const got = { lib: seg('A-BEGIN', 'A-END').length, store: seg('B-BEGIN', 'B-END').length };
  const want = { lib: {{LEN:pull-agent-lib.js}}, store: {{LEN:pull-walmart-instore.js}} };
  if (got.lib !== want.lib || got.store !== want.store) {
    return { refused: 'PASTE LENGTH MISMATCH: nothing was started. Re-read the file and paste it exactly.', got, want };
  }
  const identity = window.walmartIdentity();
  const TERMS = {{TERMS}};
  return { got, want, identity, terms: TERMS.length,
           started: tcStart('walmart', () => window.pullWalmartInStore(TERMS)) };
})()
```

A `refused` answer means fix the paste and send Step 2 again. A thrown REFUSING error means the store is wrong: see
the store rule.

## Step 3: wait

`await window.tcWait(40000)`, repeated until `done` is true (at most 45 times). Walmart paces 3.5 s a term.

## Step 4: the verdicts, then post (ONE javascript_tool call, the last in this tab)

```js
(() => {
  const unusable = window.walmartSweepVerdicts().split('\n').filter(l => l.split('|')[1] === 'UNUSABLE');
  return { unusable, sent: window.walmartFinish('{{SINK}}') };
})()
```

Then read the tab's text: the sink's reply is `ok <chars> <lines> chars=AGREE (<n>)`. Anything but AGREE is an open
item, never a pass.

## Report

```
WALMART {{DATE}}: requested {{N_TERMS}} | with rows <summary.matches> | empty <summary.empty> | unusable <summary.unusable> (<terms and why>)
injected lib <got.lib>/<want.lib> store <got.store>/<want.store> | identity <identity>
posted {{SINK}} chars <sent.chars> lines <sent.lines> first "<sent.first>" | sink reply "<reply>"
tool calls <n> | open items <list, or none>
```
