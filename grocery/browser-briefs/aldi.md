<!-- grocery\browser-briefs\aldi.md: the Aldi store agent's own steps. Joined after _common.md by
     grocery\fill-browser-brief.ps1. design\PLAN-browser-refresh-hardening-2026-10-02.md W4. -->
## The store rule

Aldi serves a different price per fulfilment mode, and only **In-Store** is a shelf price. The page header must say
In-Store and the store line must end in Omaha ("ALDI - OLA <n> - Omaha"). Never assert the OLA number: the session
has read OLA 48 and OLA 42 at different times. The mode is asserted on every term, so a session flipped to Delivery
mid-sweep settles those terms UNUSABLE. If the mode is not In-Store, set it in the page's own picker and run Step 1
again.

## Step 1: open the page

Navigate tab {{TABID}} to `https://www.aldi.us/store/aldi/storefront` and confirm the header reads In-Store. Read the
files `{{GROCERY}}\pull-agent-lib.js` and `{{GROCERY}}\pull-aldi-instore.js` with
the Read tool.

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
<<< paste pull-aldi-instore.js here, exactly >>>
/*TC-B-END*/
}
  const src = __tcInject.toString();
  const seg = (a, b) => {
    const i = src.indexOf('/*TC-' + a), j = src.indexOf('/*TC-' + b);
    return (i < 0 || j < 0) ? '' : src.slice(src.indexOf('*/', i) + 2, j).replace(/^\n+|\n+$/g, '');
  };
  const got = { lib: seg('A-BEGIN', 'A-END').length, store: seg('B-BEGIN', 'B-END').length };
  const want = { lib: {{LEN:pull-agent-lib.js}}, store: {{LEN:pull-aldi-instore.js}} };
  if (got.lib !== want.lib || got.store !== want.store) {
    return { refused: 'PASTE LENGTH MISMATCH: nothing was started. Re-read the file and paste it exactly.', got, want };
  }
  const identity = window.assertInStore();
  const TERMS = {{TERMS}};
  return { got, want, identity, terms: TERMS.length,
           started: tcStart('aldi', () => window.pullAldiSearch(TERMS)) };
})()
```

A `refused` answer means fix the paste and send Step 2 again. A thrown REFUSING error means the mode is wrong: see
the store rule.

## Step 3: wait

`await window.tcWait(40000)`, repeated until `done` is true (at most 45 times). Aldi paces 0.9 s a term plus scroll
rounds.

## Step 4: the verdicts, then post (ONE javascript_tool call, the last in this tab)

The first column of Aldi's capture is the COMMODITY id, so the finish takes the worklist's term -> id map:

```js
(() => {
  const TERMS = {{TERMS}};
  const COMMS = {{COMMS}};
  const idByTerm = {};
  TERMS.forEach((t, i) => { idByTerm[t] = COMMS[i]; });
  const unusable = window.aldiSearchVerdicts().split('\n').filter(l => l.split('|')[1] === 'UNUSABLE');
  return { unusable, sent: window.aldiFinish('{{SINK}}', idByTerm) };
})()
```

Then read the tab's text: the sink's reply is `ok <chars> <lines> chars=AGREE (<n>)`. Anything but AGREE is an open
item, never a pass.

## Report

```
ALDI {{DATE}}: requested {{N_TERMS}} | with rows <summary.matches> | empty <summary.empty> | unusable <summary.unusable> (<terms and why>)
injected lib <got.lib>/<want.lib> store <got.store>/<want.store> | store and mode <identity>
posted {{SINK}} chars <sent.chars> lines <sent.lines> first "<sent.first>" | sink reply "<reply>"
tool calls <n> | open items <list, or none>
```
