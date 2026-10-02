<!-- grocery\browser-briefs\sams.md: the Sam's Club store agent's own steps. Joined after _common.md by
     grocery\fill-browser-brief.ps1. design\PLAN-browser-refresh-hardening-2026-10-02.md W4. -->
## The store rule

Sam's prices are per club, and Omaha has two. The board's club is **13130 L St, Omaha 68137** (Brad's ruling
2026-10-02). `samsIdentity()` reads the club the session is on and refuses a page that names none. If the club is
not L St, SWITCH THE CLUB to L St in the page's own club picker and run Step 1 again. `build-sams-deals` refuses a
capture with no store line, an UNRECORDED one or two clubs, so post the emitter's output unaltered.

## Step 1: open the page

Navigate tab {{TABID}} to `https://www.samsclub.com/`. Read the files `{{GROCERY}}\pull-agent-lib.js`
and `{{GROCERY}}\pull-sams-instore.js` with the Read tool.

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
<<< paste pull-sams-instore.js here, exactly >>>
/*TC-B-END*/
}
  const src = __tcInject.toString();
  const seg = (a, b) => {
    const i = src.indexOf('/*TC-' + a), j = src.indexOf('/*TC-' + b);
    return (i < 0 || j < 0) ? '' : src.slice(src.indexOf('*/', i) + 2, j).replace(/^\n+|\n+$/g, '');
  };
  const got = { lib: seg('A-BEGIN', 'A-END').length, store: seg('B-BEGIN', 'B-END').length };
  const want = { lib: {{LEN:pull-agent-lib.js}}, store: {{LEN:pull-sams-instore.js}} };
  if (got.lib !== want.lib || got.store !== want.store) {
    return { refused: 'PASTE LENGTH MISMATCH: nothing was started. Re-read the file and paste it exactly.', got, want };
  }
  const identity = window.samsIdentity();
  const TERMS = {{TERMS}};
  return { got, want, identity, terms: TERMS.length,
           started: tcStart('sams', () => window.pullSamsInStore(TERMS)) };
})()
```

A `refused` answer means fix the paste and send Step 2 again. A thrown REFUSING error means the club is wrong or
unreadable: see the store rule.

## Step 3: wait

`await window.tcWait(40000)`, repeated until `done` is true (at most 45 times). Sam's paces 2.6 s a term.

## Step 4: the verdicts, then post (ONE javascript_tool call, the last in this tab)

```js
(() => {
  const unusable = window.samsSweepVerdicts().split('\n').filter(l => l.split('|')[1] === 'UNUSABLE');
  return { unusable, sent: window.samsFinish('{{SINK}}') };
})()
```

Then read the tab's text: the sink's reply is `ok <chars> <lines> chars=AGREE (<n>)`. Anything but AGREE is an open
item, never a pass.

## Report

```
SAM'S CLUB {{DATE}}: requested {{N_TERMS}} | with rows <summary.matches> | empty <summary.empty> | unusable <summary.unusable> (<terms and why>)
injected lib <got.lib>/<want.lib> store <got.store>/<want.store> | club <identity>
posted {{SINK}} chars <sent.chars> lines <sent.lines> first "<sent.first>" | sink reply "<reply>"
tool calls <n> | open items <list, or none>
```
