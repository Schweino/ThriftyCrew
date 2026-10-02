<#
  test-pull-post-route.ps1 - the browser lane's post route, in-page wait and per-store finish functions.

  design\PLAN-browser-refresh-hardening-2026-10-02.md W4. On 2026-10-02 the brief told all four store agents to post
  into a hidden iframe and 8 of 8 posts failed; tcPostToSink in grocery\pull-agent-lib.js is now the only route, and
  this suite pins it, tcStart/tcWait, walmartFinish/samsFinish/aldiFinish/farewayFinish and the window exports.
  Split out of test-pull-agent-lib.ps1 the day it was written, to keep that file under the 1,000-line budget.

  THE SOURCE IS READ, NEVER COPIED: every file loads untouched and only the browser globals are supplied. If node is
  not found this prints BLIND and exits 3, never a pass (test-pull-agent-lib.ps1's header has the node locations).

  Usage: .\test-pull-post-route.ps1 -SelfTest
#>
# Self-test: node runs fixtures against the lane's JS source files, each read by path; nothing else in the repo.
# gate-inputs: grocery\test-pull-post-route.ps1, grocery\pull-agent-lib.js, grocery\pull-walmart-instore.js, grocery\pull-sams-instore.js, grocery\pull-aldi-instore.js, grocery\pull-fareway-shop.js
[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $SelfTest) { Write-Output 'test-pull-post-route: run with -SelfTest'; exit 2 }

function Find-Node {
  # PATH first, then the known local installs. NOT a hardcoded absolute path: the estate has already
  # shipped a fixture that passed on Brad's box and failed everywhere else for exactly that reason
  # (see the derived-path note in lib\ghost-drift-lib.ps1).
  $c = Get-Command node -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($p in @(
      'C:\Program Files\nodejs\node.exe',
      'C:\Codex\node-v24.15.0-win-x64\node.exe',
      'C:\Codex\tools\node-v22.11.0-win-x64\node.exe')) {
    if (Test-Path $p) { return $p }
  }
  foreach ($d in @(Get-ChildItem 'C:\Codex' -Directory -Filter 'node-v*' -ErrorAction SilentlyContinue)) {
    $p = Join-Path $d.FullName 'node.exe'
    if (Test-Path $p) { return $p }
  }
  return $null
}

$node = Find-Node
if (-not $node) {
  Write-Output 'test-pull-post-route: BLIND - node was not found, so the post route was NOT tested. This run proves nothing about it.'
  exit 3
}
$bad = 0

# --- 10. THE POST ROUTE, THE IN-PAGE WAIT AND THE FINISH FUNCTIONS (2026-10-02) ---------------------------------
# design\PLAN-browser-refresh-hardening-2026-10-02.md W4. FOUNDING BUG: 2026-10-02, the brief told all four agents to
# post into a hidden iframe target, and 8 of 8 posts failed; the same form with no target landed AGREE every time.
# tcPostToSink is now the only route, so the form it builds is pinned here: on the tab's own document, no target,
# POST text/plain, one textarea named csv, ?chars= the plain length, submit deferred. And the 2026-10-01 wrapper
# defect (the store files' entry points are block-scoped consts, so a starter after the block threw ReferenceError)
# is pinned by the window exports. Every file loads UNTOUCHED; only the browser globals are supplied.
$jsP = @'
const fs = require('fs');
const lib = fs.readFileSync(process.argv[2], 'utf8');
const wal = fs.readFileSync(process.argv[3], 'utf8');
const sam = fs.readFileSync(process.argv[4], 'utf8');
const ald = fs.readFileSync(process.argv[5], 'utf8');
const fws = fs.readFileSync(process.argv[6], 'utf8');
let bad = 0, ran = 0;
function T(n, ok, got) { ran++; if (ok) console.log('  ok    ' + n); else { console.log('  X     ' + n + '   got: ' + got); bad++; } }
function fakeDoc() {
  const made = [], appended = [], submitted = [];
  const el = tag => { const e = { tag, style: {}, children: [], appendChild(c) { this.children.push(c); }, submit() { submitted.push(this); } }; made.push(e); return e; };
  return { createElement: el, body: { appendChild: e => appended.push(e) }, made, appended, submitted };
}
function loadLib(win) { return new Function('window', lib + '\nreturn { tcPostToSink, tcStart, tcWait };')(win); }
(async () => {
  try {
    const L = loadLib(undefined);
    const doc = fakeDoc();
    let queued = null;
    const text = '#tc-store store="Omaha L St Supercenter" id="5361"\nq|n|lp\nmilk|Milk|$3.12';
    const sent = L.tcPostToSink('walmart-capture-2026-10-02', text, { document: doc, schedule: fn => { queued = fn; } });
    const form = doc.appended[0] || {};
    const field = (form.children || [])[0] || {};
    T('MUST FIRE  the 2026-10-02 shape is gone: the form has NO target and is appended to the tab\'s own document body',
      doc.appended.length === 1 && form.tag === 'form' && (form.target === undefined || form.target === ''), JSON.stringify({ n: doc.appended.length, target: form.target }));
    T('CLEAN TWIN  POST, text/plain, to the sink port, with ?chars= the plain text length',
      form.method === 'POST' && form.enctype === 'text/plain' && form.action === 'http://localhost:8791/walmart-capture-2026-10-02?chars=' + text.length, JSON.stringify({ m: form.method, e: form.enctype, a: form.action }));
    T('CLEAN TWIN  one textarea named csv carries the text exactly (an input would drop its line breaks)',
      form.children.length === 1 && field.tag === 'textarea' && field.name === 'csv' && field.value === text, JSON.stringify({ tag: field.tag, name: field.name, same: field.value === text }));
    const before = doc.submitted.length;
    if (queued) queued();
    T('MUST FIRE  submit is deferred to the scheduler, so the tool call returns before the tab navigates',
      before === 0 && doc.submitted.length === 1 && doc.submitted[0] === form, 'before=' + before + ' after=' + doc.submitted.length);
    T('CLEAN TWIN  it returns what it sent: chars, lines and the first line',
      sent.chars === text.length && sent.lines === 3 && sent.first.startsWith('#tc-store ') && sent.name === 'walmart-capture-2026-10-02', JSON.stringify(sent));
    let e1 = '', e2 = '';
    try { L.tcPostToSink('walmart-capture-x', '', { document: fakeDoc(), schedule: () => {} }); } catch (e) { e1 = String(e.message); }
    try { L.tcPostToSink('../walmart', 'x', { document: fakeDoc(), schedule: () => {} }); } catch (e) { e2 = String(e.message); }
    T('MUST FIRE  an empty capture and a path-shaped name are refused before any form is built', /nothing to post/.test(e1) && /sink name/.test(e2), e1 + ' / ' + e2);

    // tcStart / tcWait. The run is held open on a promise this test releases, never on a clock (og-36): the
    // short wait must come back not-done, and the long wait must come back the moment the run ends.
    let release = null;
    L.tcStart('fixture', () => new Promise(r => { release = r; }), () => ({ i: 1, n: 2 }));
    const w1 = await L.tcWait(5);
    T('MUST FIRE  a wait that runs out reports done=false with the progress read, and no summary', w1.done === false && w1.summary === null && w1.progress && w1.progress.n === 2, JSON.stringify(w1));
    const pending = L.tcWait(600000);
    release({ matches: 7, empty: 1, unusable: 0, remaining: 0, timing: { verdict: 'CLEAN' } });
    const w2 = await pending;
    T('CLEAN TWIN  a long wait returns as soon as the run ends, with the summary, not after its whole budget',
      w2.done === true && w2.error === null && w2.summary.matches === 7 && w2.summary.timing === 'CLEAN', JSON.stringify(w2));
    L.tcStart('thrower', () => { throw new Error('assertIdentity refused'); });
    const w3 = await L.tcWait(600000);
    T('MUST FIRE  a run that throws is DONE with its error kept, never a silent hang', w3.done === true && /assertIdentity refused/.test(w3.error || ''), JSON.stringify(w3));
    let e3 = '';
    const L2 = loadLib({});
    try { await L2.tcWait(1); } catch (e) { e3 = String(e.message); }
    T('MUST FIRE  waiting with nothing started throws', /nothing was started/.test(e3), e3);

    // THE FINISH FUNCTIONS. A stub post records exactly what each would send.
    const posts = [];
    const post = (name, t) => { posts.push({ name, t }); return { name, chars: t.length }; };
    const ls = obj => ({ getItem: k => (k in obj ? obj[k] : null), setItem() {}, removeItem() {} });
    const fin = [];
    const winW = {};
    const W = new Function('wallWhy', 'fetch', 'localStorage', 'tcPostToSink', 'window',
      wal + '\nreturn { walmartFinish, walmartSweepToCsv, WALMART_STORAGE_KEY };');
    const wEmpty = W(() => '', null, ls({}), post, winW);
    const keyW = wEmpty.WALMART_STORAGE_KEY;
    const resW = { milk: { v: 'MATCHES', rows: [{ n: 'Great Value Whole Milk, 1 gal', lp: '$3.12', up: '', id: '10450114', si: '5361', sz: '68137', st: 'Omaha L St Supercenter', sr: 'response' }] } };
    const wFull = W(() => '', null, ls({ [keyW]: JSON.stringify(resW) }), post, {});
    fin.push(['walmart', wEmpty.walmartFinish, wFull.walmartFinish, wFull.walmartSweepToCsv, 'walmart-capture-2026-10-02', winW, 'walmartFinish']);

    const winS = {};
    const S = new Function('localStorage', 'tcPostToSink', 'window', sam + '\nreturn { samsFinish, samsSweepToCsv, SAMS_STORAGE_KEY };');
    const sEmpty = S(ls({}), post, winS);
    const resS = { eggs: { v: 'MATCHES', rows: [{ n: "Member's Mark Eggs, 24 ct", lp: '$5.98', up: '', id: '1', cl: '13130 L St Omaha NE' }] } };
    const sFull = S(ls({ [sEmpty.SAMS_STORAGE_KEY]: JSON.stringify(resS) }), post, {});
    fin.push(['sams', sEmpty.samsFinish, sFull.samsFinish, sFull.samsSweepToCsv, 'sams-capture-2026-10-02', winS, 'samsFinish']);

    const winA = {};
    const A = new Function('localStorage', 'tcPostToSink', 'window', ald + '\nreturn { aldiFinish, aldiSearchToCsv, ALDI_SEARCH_STORAGE_KEY };');
    const aEmpty = A(ls({}), post, winA);
    const resA = { kale: { v: 'MATCHES', rows: [{ name: 'Kale', prices: 'Current price: $1.99', unit: '', size: '16 oz', href: '/k', st: 'ALDI - OLA 42 - Omaha', md: 'In-Store' }] } };
    const aFull = A(ls({ [aEmpty.ALDI_SEARCH_STORAGE_KEY]: JSON.stringify(resA) }), post, {});
    const idMap = { kale: 'kale' };
    fin.push(['aldi', n => aEmpty.aldiFinish(n, idMap), n => aFull.aldiFinish(n, idMap), () => aFull.aldiSearchToCsv(idMap), 'aldi-capture-2026-10-02', winA, 'aldiFinish']);

    for (const [store, finEmpty, finFull, build, name, win, exported] of fin) {
      let ew = '', ee = '';
      try { finFull(store === 'walmart' ? 'sams-capture-2026-10-02' : 'walmart-capture-2026-10-02'); } catch (e) { ew = String(e.message); }
      const n0 = posts.length;
      try { finEmpty(name); } catch (e) { ee = String(e.message); }
      T('MUST FIRE  ' + store + ': another store\'s sink name is refused, and a sweep with no rows posts nothing',
        /sink name must start/.test(ew) && /nothing was posted/.test(ee) && posts.length === n0, ew + ' / ' + ee + ' / posts ' + (posts.length - n0));
      const r = finFull(name);
      const p = posts[posts.length - 1];
      T('CLEAN TWIN  ' + store + ': the capture is posted UNALTERED under its own name, opening with its #tc-store line',
        p.name === name && p.t === build() && p.t.startsWith('#tc-store ') && r.chars === p.t.length, JSON.stringify({ name: p.name, first: p.t.split('\n')[0] }));
      T('MUST FIRE  ' + store + ': the finish function is exported to window, so a call after the inject block resolves',
        typeof win[exported] === 'function', typeof win[exported]);
    }
    let ea = '';
    try { aFull.aldiFinish('aldi-capture-2026-10-02'); } catch (e) { ea = String(e.message); }
    T('MUST FIRE  aldi: no term -> commodity map is refused, because the first column is the commodity id', /commodity id map/.test(ea), ea);

    const winF = { __fwSweep: { done: true, lines: [{ id: 'kale', term: 'kale', candidates: [{ name: 'Kale', loc: '531573' }] }], errors: [{ id: 'x', term: 'x', error: 'UNSETTLED' }], aborted: '' } };
    const F = new Function('window', 'module', 'tcPostToSink', fws + '\nreturn { farewayFinish, farewaySweepJsonl };')(winF, undefined, post);
    const fr = F.farewayFinish('fareway-shop-2026-10-02');
    const fp = posts[posts.length - 1];
    T('CLEAN TWIN  fareway: the sweep\'s JSON lines are posted UNALTERED, with the error count and abort beside the post',
      fp.name === 'fareway-shop-2026-10-02' && fp.t === F.farewaySweepJsonl() && fr.errors === 1 && fr.aborted === '', JSON.stringify(fr));
    winF.__fwSweep = { done: true, lines: [], errors: [], aborted: 'term "a": wrong store' };
    let ef = '';
    try { F.farewayFinish('fareway-shop-2026-10-02'); } catch (e) { ef = String(e.message); }
    T('MUST FIRE  fareway: a sweep that read no term posts nothing', /nothing to post/.test(ef), ef);
    T('MUST FIRE  fareway: the finish function is exported to window', typeof winF.farewayFinish === 'function', typeof winF.farewayFinish);
    const winL = {};
    loadLib(winL);
    T('MUST FIRE  the lib exports tcPostToSink, tcStart and tcWait to window', ['tcPostToSink', 'tcStart', 'tcWait'].every(k => typeof winL[k] === 'function'), Object.keys(winL).join(','));
  } catch (e) { console.log('  X     the post-route test threw: ' + (e && e.stack)); bad++; }
  // A literal case list knows its own number, so a shortfall is a defect rather than a smaller tree.
  T('the literal case list ran every case above this one', ran === 24, 'ran=' + ran);
  process.exit(bad === 0 ? 0 : 1);
})();
'@
$tmpP = Join-Path ([IO.Path]::GetTempPath()) ('postroute-' + [guid]::NewGuid().ToString('N') + '.js')
[IO.File]::WriteAllText($tmpP, $jsP, (New-Object System.Text.UTF8Encoding($false)))
try {
  & $node $tmpP (Join-Path $here 'pull-agent-lib.js') (Join-Path $here 'pull-walmart-instore.js') (Join-Path $here 'pull-sams-instore.js') (Join-Path $here 'pull-aldi-instore.js') (Join-Path $here 'pull-fareway-shop.js')
  if ($LASTEXITCODE -ne 0) { $bad++ }
} finally { Remove-Item $tmpP -Force -ErrorAction SilentlyContinue }

if ($bad -eq 0) { Write-Output 'test-pull-post-route SELF-TEST PASS'; exit 0 }
Write-Output ("test-pull-post-route SELF-TEST FAIL: {0} case(s)" -f $bad); exit 1
