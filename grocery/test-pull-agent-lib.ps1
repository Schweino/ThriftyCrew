<#
  test-pull-agent-lib.ps1 - the browser-pull JS lane's first automated coverage.

  WHY IT DID NOT EXIST (2026-08-31). grocery\pull-agent-lib.js and the four store agents beside it are
  the WHOLE capture path for the walled stores - Walmart, Sam's Club, Fareway, Aldi. Between them they
  decide whether a term was EMPTY (the store does not stock it) or UNUSABLE (we were blocked), which is
  the distinction pull-agent-lib's own header calls the reason it exists: "a false EMPTY is a silent
  claim the store does not stock an item". Not one line of that was under test. Every -SelfTest in this
  tree is PowerShell, so run-gates discovered 158 of them and none of them could see the JS.

  WHAT IT TESTS TODAY: wallWhy(), added 2026-08-31 so a bot-wall verdict keeps its own evidence.
  Every agent used to record a wall as the bare string 'bot-wall', which is a verdict with the proof
  thrown away - afterwards nothing could say which phrase matched or what surrounded it, so a one-term
  blip and a store-wide block read identically. That cost a false "Walmart is walled" report on
  2026-08-31 over a capture that had in fact completed all 592 terms.

  AND SINCE 2026-09-10: the Aldi capture carries the store line it was read at, per row and in a
  #tc-store line at the top of the CSV, because build-aldi-regular now refuses a capture without one.

  AND SINCE 2026-09-02: the Walmart price extractor, against a fixture for each of the three payload
  shapes Walmart has served. Every one of those moves was discovered in production, by a capture that
  reported healthy stores as carrying nothing - the last one dropped all 127 item nodes on a live
  search. A shape change is the one failure this lane cannot self-detect, so it is pinned here.

  THE SOURCE IS READ, NEVER COPIED. The fixture extracts wallWhy from the real pull-agent-lib.js and
  evals it. A test carrying its own copy of the function proves the copy works, which is the
  duplicated-constant trap the lib's own header was written against.

  ON NOT FINDING NODE. If node cannot be located this prints BLIND and exits 0, and that is a
  deliberate, narrow exception to the estate's "unknown is not a pass" rule - stated here rather than
  hidden. The alternative is a gate that goes red on every machine without node, which is a gate
  someone removes. The line says BLIND in capitals so a green run that proved nothing is still legible,
  and node IS present on the box this lane actually runs on (it is a browser-driving lane).

  Usage: .\test-pull-agent-lib.ps1 -SelfTest
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

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

if (-not $SelfTest) { Write-Output 'test-pull-agent-lib: pass -SelfTest'; exit 0 }

$node = Find-Node
if (-not $node) {
  Write-Output 'test-pull-agent-lib: BLIND - node was not found on PATH or in the known install locations, so the browser-pull JS lane was NOT tested. This run proves nothing about it.'
  Write-Output 'test-pull-agent-lib SELF-TEST BLIND'
  exit 0
}

$lib = Join-Path $here 'pull-agent-lib.js'
if (-not (Test-Path $lib)) { Write-Output 'test-pull-agent-lib: pull-agent-lib.js is MISSING'; exit 1 }

# --- 1. every file in the lane must at least PARSE -------------------------------------------------
$bad = 0
$lane = @('pull-agent-lib.js', 'pull-walmart-instore.js', 'pull-sams-instore.js', 'pull-fareway-instore.js', 'pull-aldi-instore.js')
foreach ($f in $lane) {
  $p = Join-Path $here $f
  if (-not (Test-Path $p)) { Write-Output ("  X     " + $f + " is missing from the lane"); $bad++; continue }
  # Start-Process WITH REDIRECTED STREAMS, not `& node ... 2>&1`. Under $ErrorActionPreference='Stop'
  # a native child's first stderr line is a TERMINATING error, so the plain call made an unparseable
  # file KILL this script instead of reporting it - the case died silently and the neuter that proved
  # it came back 0 red. Same trap that took ops\run-gates.ps1 down this morning; see the note in
  # meal-prep\pipeline\ingredient-resolutions.ps1.
  $so = [IO.Path]::GetTempFileName(); $se = [IO.Path]::GetTempFileName()
  $pi = Start-Process -FilePath $node -ArgumentList @('--check', $p) -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $so -RedirectStandardError $se
  $err = [string](Get-Content $se -Raw); if ($null -eq $err) { $err = '' }
  Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
  if ($pi.ExitCode -eq 0) { Write-Output ("  ok    " + $f + " parses") }
  else {
    $first = (($err -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    Write-Output ("  X     " + $f + " DOES NOT PARSE - the capture lane would fail at injection: " + ([string]$first).Trim())
    $bad++
  }
}

# --- 2. wallWhy's behaviour, against the real source ------------------------------------------------
$js = @'
const fs = require('fs');
// argv[2], NOT argv[1]: for `node script.js <arg>` argv[0] is node and argv[1] is the SCRIPT, so
// argv[1] made this read its own temp file, find no wallWhy in it, and report the lib as missing it.
const src = fs.readFileSync(process.argv[2], 'utf8');
const m = src.match(/function wallWhy\(html, phrases\) \{[\s\S]*?\n\}/);
if (!m) { console.log('  X     wallWhy is not defined in pull-agent-lib.js'); process.exit(1); }
eval(m[0]);
let bad = 0;
function T(n, ok, got) { if (ok) console.log('  ok    ' + n); else { console.log('  X     ' + n + '   got: ' + got); bad++; } }
const P = ['robot or human', 'access denied', 'px-captcha'];
const wall = '<html><head><title>Robot or human?</title></head><body>Please verify you are not a robot.</body></html>';
const r1 = wallWhy(wall, P);
T('a wall verdict NAMES the phrase that matched', r1.indexOf('[robot or human]') >= 0, r1);
T('...and records where in the body it matched', /@\d+/.test(r1), r1);
T('...and carries the surrounding text, not just the phrase', r1.indexOf(' :: ') >= 0 && r1.length > 40, r1);
T('...and still begins with bot-wall, so old greps still find it', r1.indexOf('bot-wall') === 0, r1);
T('MUST NOT FIRE  a page with no wall phrase returns the bare verdict', wallWhy('an ordinary product page', P) === 'bot-wall', wallWhy('an ordinary product page', P));
T('matching is case-insensitive on both sides', wallWhy('ACCESS DENIED to this page', P).indexOf('[access denied]') >= 0, wallWhy('ACCESS DENIED', P));
const a = wallWhy('the page says access denied here', P), b = wallWhy('the page says px-captcha here', P);
T('MUST FIRE  two DIFFERENT walls produce DIFFERENT evidence (the entire point)', a !== b, a + '  vs  ' + b);
T('the context is collapsed to one line, so it cannot break a jsonl row', wallWhy('noise\n\n\taccess denied\n\n  spread  over  lines', P).indexOf('\n') < 0, 'newline survived');
let threw = false;
try { wallWhy(null, P); wallWhy(undefined, P); wallWhy('', P); } catch (e) { threw = true; }
T('MUST NOT THROW  an empty or absent body is not an exception', !threw, 'threw');
process.exit(bad === 0 ? 0 : 1);
'@
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wallwhy-' + [guid]::NewGuid().ToString('N') + '.js')
[IO.File]::WriteAllText($tmp, $js, (New-Object System.Text.UTF8Encoding($false)))
try {
  & $node $tmp $lib
  if ($LASTEXITCODE -ne 0) { $bad++ }
} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

# --- 3. and every agent that detects a wall must actually USE it ------------------------------------
# Without this, wallWhy could be perfect and still be called by nobody - which is the state the lane
# was in before today, with three inline copies of the bare verdict.
foreach ($f in @('pull-walmart-instore.js', 'pull-sams-instore.js', 'pull-fareway-instore.js')) {
  $txt = [IO.File]::ReadAllText((Join-Path $here $f))
  $needle = 'wall' + 'Why('          # built by concatenation: a literal here could match this file
  if ($txt.Contains($needle)) { Write-Output ("  ok    " + $f + " reports its wall through the shared evidence helper") }
  else { Write-Output ("  X     " + $f + " still records a wall without evidence"); $bad++ }
  if ($txt -match "why:\s*'bot-wall'") { Write-Output ("  X     " + $f + " still carries a bare 'bot-wall' verdict"); $bad++ }
}

# --- 4. the Walmart price extractor, against every payload shape we have actually seen -------------
# Walmart's price shape has moved THREE times (2026-08-22 flat strings, 2026-09-02 priceDetails), and
# each move was found in production by a capture that reported healthy stores carrying nothing. The
# 2026-09-02 one dropped all 127 item nodes on a live miracle-whip search. This is the case that would
# have caught it before the agent ran, so it is pinned here with a fixture per shape.
#
# THE AGENT IS LOADED, NOT REIMPLEMENTED. The fixture wraps the real pull-walmart-instore.js in a
# Function and calls walmartProbe with fetch stubbed, so what is under test is the shipped file - the
# same rule section 2 follows, for the same reason.
$jsW = @'
const fs = require('fs');
const lib = fs.readFileSync(process.argv[2], 'utf8');
const src = fs.readFileSync(process.argv[3], 'utf8');
const wm = lib.match(/function wallWhy\(html, phrases\) \{[\s\S]*?\n\}/);
if (!wm) { console.log('  X     wallWhy is not defined in pull-agent-lib.js'); process.exit(1); }
eval(wm[0]);

let bad = 0;
function T(n, ok, got) { if (ok) console.log('  ok    ' + n); else { console.log('  X     ' + n + '   got: ' + got); bad++; } }

// The agent is a file of consts and function declarations, so the whole of it loads here untouched;
// only fetch (and wallWhy, which lives in the lib) is supplied from outside.
let page = '';
const stubFetch = async () => ({ status: 200, text: async () => page });
const { walmartProbe } = new Function('wallWhy', 'fetch', src + '\nreturn { walmartProbe };')(wallWhy, stubFetch);

const nextData = o => '<html><body><script id="__NEXT_DATA__" type="application/json">' +
  JSON.stringify(o) + '</scr' + 'ipt></body></html>';
// EVERY PAYLOAD CARRIES ITS STORE NOW (2026-09-12). walmartProbe refuses rows it cannot attribute to
// a store, so a fixture without a store block is not a payload the shipped agent will read at all -
// these price cases would every one come back UNUSABLE for a reason that is not about the price shape.
// Section 6 is where the store read itself is put under test.
const stack = items => ({ props: { pageProps: { initialData: {
  searchResult: { itemStacks: [{ items }] },
  pageMetadata: { location: { storeId: 5361, postalCode: '68137', displayName: 'Omaha L St Supercenter' } },
} } } });
const probe = async items => { page = nextData(stack(items)); return await walmartProbe('miracle whip'); };

// 2026-09-02, measured: every flat field is "" and the price is one level down in priceDetails.
const third = extra => ({
  name: 'Kraft Miracle Whip Dressing, 30 fl oz Jar',
  usItemId: '10450996',
  sellerName: 'Walmart',
  fulfillmentType: 'IN_STORE',
  priceInfo: Object.assign({
    linePrice: '', linePriceDisplay: '', itemPrice: '', unitPrice: '', wasPrice: '',
    priceDetails: { priceLines: [
      { lineType: 'CURRENT_PRICE', values: [{ key: 'PRICE', value: '8.97' }] },
      { lineType: 'UNIT_PRICE', values: [{ key: 'UNIT_PRICE', value: '18.7 00a2/fl oz' }] },
    ] },
  }, extra || {}),
});

(async () => {
  const r3 = await probe([third()]);
  T('THE 2026-09-02 SHAPE  a priceDetails-only payload yields a row at all', r3.state === 'MATCHES' && r3.rows.length === 1, r3.state + ' / ' + r3.rows.length + ' row(s) / ' + (r3.why || ''));
  const w = r3.rows[0] || {};
  T('...and the price is the CURRENT_PRICE line, not the empty-string linePrice', w.lp === '$8.97', w.lp);
  T('...synthesised WITH the dollar sign, or Build-Row rejects it as "no linePrice"', typeof w.lp === 'string' && w.lp.indexOf('$') === 0, w.lp);
  T('...and the unit price keeps its basis verbatim', w.up === '18.7 00a2/fl oz', w.up);
  T('...an empty wasPrice does NOT travel as a was-price', w.was == null || w.was === '', JSON.stringify(w.was));
  T('...and the shelf signal still rides along', w.sel === 'Walmart' && w.ff === 'IN_STORE', w.sel + ' / ' + w.ff);

  // The ordering claim, made falsifiable: a stale flat field must not beat the priceDetails line.
  const stale = third({ linePrice: '$1.00', linePriceDisplay: '$1.00' });
  const rOrd = await probe([stale]);
  T('MUST FIRE  priceDetails is read FIRST, ahead of a disagreeing flat field', (rOrd.rows[0] || {}).lp === '$8.97', (rOrd.rows[0] || {}).lp);

  // Both older shapes are still real and must still be read.
  const r2 = await probe([{ name: 'Great Value Milk, 1 gal', usItemId: '2', priceInfo: { linePrice: '$1.74', linePriceDisplay: '$1.74', unitPrice: '2.7 00a2/fl oz', wasPrice: '' } }]);
  T('THE 2026-08-22 SHAPE  flat display strings still parse, and travel verbatim', (r2.rows[0] || {}).lp === '$1.74', (r2.rows[0] || {}).lp);
  T('...with its unit price intact', (r2.rows[0] || {}).up === '2.7 00a2/fl oz', (r2.rows[0] || {}).up);
  const r1 = await probe([{ name: 'Butter 16 oz', usItemId: '3', priceInfo: { currentPrice: { price: 3.27 }, unitPrice: { price: 20.4 } } }]);
  T('THE ORIGINAL OBJECT SHAPE  a numeric .price still becomes a "$x.xx" string', (r1.rows[0] || {}).lp === '$3.27', (r1.rows[0] || {}).lp);

  // A rollback in the new shape: the was-price is a WAS_PRICE line, and the badge is unchanged.
  const rb = await probe([Object.assign(third({ priceDetails: { priceLines: [
    { lineType: 'CURRENT_PRICE', values: [{ key: 'PRICE', value: '4.87' }] },
    { lineType: 'WAS_PRICE', values: [{ key: 'WAS_PRICE', value: '5.96' }] },
  ] } }), { badges: { flags: [{ key: 'ROLLBACK' }] } })]);
  const wr = rb.rows[0] || {};
  T('a rollback survives the move  was-price read from the WAS_PRICE line', String(wr.was).indexOf('5.96') >= 0, wr.was);
  T('...and the ROLLBACK badge still sets rb', wr.rb === 1, wr.rb);

  // Absence is UNKNOWN. Never a default - "" and "SHIP" are about to mean opposite things.
  const rSel = await probe([{ name: 'No seller stated', usItemId: '4', priceInfo: { priceDetails: { priceLines: [{ lineType: 'CURRENT_PRICE', values: [{ key: 'PRICE', value: '2.50' }] }] } } }]);
  T('MUST NOT DEFAULT  a node with no sellerName/fulfillmentType emits EMPTY, not a guess', (rSel.rows[0] || {}).sel === '' && (rSel.rows[0] || {}).ff === '', JSON.stringify([(rSel.rows[0] || {}).sel, (rSel.rows[0] || {}).ff]));

  // BLINDNESS IS NOT EMPTINESS - the guard that stopped 12 false not-carried rulings on 2026-09-02.
  const rBlind = await probe([{ name: 'Shape we cannot read', usItemId: '5', priceInfo: { linePrice: '', linePriceDisplay: '', unitPrice: '' } }]);
  T('MUST NOT  item nodes present but no row kept is UNUSABLE, never EMPTY', rBlind.state === 'UNUSABLE', rBlind.state + ' / ' + (rBlind.why || ''));
  T('...and the verdict says how many item nodes we saw', /item node/.test(rBlind.why || ''), rBlind.why);
  const rEmpty = await probe([]);
  T('...while a payload with NO item nodes is still an honest EMPTY', rEmpty.state === 'EMPTY', rEmpty.state + ' / ' + (rEmpty.why || ''));

  page = '<html><head><title>Robot or human?</title></head><body>please verify you are not a robot</body></html>';
  const rWall = await walmartProbe('miracle whip');
  T('a walled page is UNUSABLE and keeps its evidence', rWall.state === 'UNUSABLE' && (rWall.why || '').indexOf('bot-wall') === 0, rWall.state + ' / ' + rWall.why);

  process.exit(bad === 0 ? 0 : 1);
})();
'@
$wal = Join-Path $here 'pull-walmart-instore.js'
$tmpW = Join-Path ([IO.Path]::GetTempPath()) ('wmprice-' + [guid]::NewGuid().ToString('N') + '.js')
[IO.File]::WriteAllText($tmpW, $jsW, (New-Object System.Text.UTF8Encoding($false)))
try {
  & $node $tmpW $lib $wal
  if ($LASTEXITCODE -ne 0) { $bad++ }
} finally { Remove-Item $tmpW -Force -ErrorAction SilentlyContinue }

# --- 5. the Aldi capture must carry the store it was READ at ----------------------------------------
# 2026-09-10. assertInStore() read the store line on every term and nothing kept it, so the capture had
# no store and build-aldi-regular wrote `source` from a literal: OLA 42 on every file for six weeks,
# including a fortnight the session was reading OLA 48. The probe now puts the store and mode on each
# row and aldiSearchToCsv opens the capture with a #tc-store line; the builder refuses a capture without
# one. The agent file loads UNTOUCHED; only the page (document, window, location), its storage, and a
# setTimeout that fires at once are supplied, so the probe's settle loops cost nothing.
$jsA = @'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
let bad = 0;
function T(n, ok, got) { if (ok) console.log('  ok    ' + n); else { console.log('  X     ' + n + '   got: ' + got); bad++; } }

function makePage(bodyText, tiles) {
  const loc = { search: '' };
  let mounted = [];
  const doc = { body: { innerText: bodyText }, documentElement: { scrollHeight: 1000 }, querySelectorAll: () => mounted };
  const win = { scrollTo: () => {}, __do_not_use_me_history: { push: p => { loc.search = p.slice(p.indexOf('?')); mounted = tiles; } } };
  return { doc, win, loc };
}
const tile = (id, slug, text) => ({ getAttribute: k => (k === 'href' ? '/store/aldi/products/' + id + '-' + slug : null), innerText: text });
const load = (page, kv) => new Function('document', 'window', 'location', 'localStorage', 'setTimeout',
  src + '\nreturn { assertInStore, aldiSearchProbe, aldiSearchToCsv };')(
  page.doc, page.win, page.loc,
  { getItem: k => (k in kv ? kv[k] : null), setItem: (k, v) => { kv[k] = String(v); } },
  fn => { Promise.resolve().then(fn); return 0; });

(async () => {
  const HEAD = 'In-Store \u00b7 open 9am - 8pm\nALDI - OLA 42 - Omaha\nSearch';
  const tiles = [
    tile('1', 'goldhen-grade-a-large-eggs-12-ct', 'Goldhen Eggs\nCurrent price: $1.65\n12 ct'),
    tile('2', 'friendly-farms-whole-milk-1-gal', 'Whole Milk\nCurrent price: $2.19\n1 gal'),
  ];
  const agent = load(makePage(HEAD, tiles), {});
  const who = agent.assertInStore();
  T('assertInStore reads the store line off the page', who.store === 'ALDI - OLA 42 - Omaha' && who.mode === 'In-Store', JSON.stringify(who));

  const r = await agent.aldiSearchProbe('goldhen eggs');
  T('every row the probe keeps carries the store line it read (st)', r.state === 'MATCHES' && r.rows.length === 2 && r.rows.every(x => x.st === 'ALDI - OLA 42 - Omaha'), r.state + ' ' + JSON.stringify(r.rows));
  T('...and the mode it read (md)', r.rows.every(x => x.md === 'In-Store'), JSON.stringify(r.rows.map(x => x.md)));

  const rDel = await load(makePage('Delivery \u00b7 by 3pm\nALDI - OLA 42 - Omaha', tiles), {}).aldiSearchProbe('goldhen eggs');
  T('MUST FIRE  a Delivery session keeps no rows at all', rDel.state === 'UNUSABLE' && rDel.rows.length === 0, rDel.state);

  // The emitter, over what runPacedSweep persists: { term: { v, why, rows } }.
  const KEY = 'TC_ALDI_SEARCH';
  const kv = {};
  kv[KEY] = JSON.stringify({ 'goldhen eggs': { v: 'MATCHES', why: null, rows: r.rows }, kale: { v: 'EMPTY', why: 'no results', rows: [] } });
  const csv = load(makePage(HEAD, []), kv).aldiSearchToCsv({ 'goldhen eggs': 'eggs' }).split('\n');
  T('CLEAN TWIN  the capture OPENS with the store line, counted', csv[0] === '#tc-store store="ALDI - OLA 42 - Omaha" mode="In-Store" rows=2', csv[0]);
  T('...then the column header, so the driver prepends nothing', csv[1] === 'id|term|name|prices|unit|size|href', csv[1]);
  T('...then exactly the rows, commodity id first', csv.length === 4 && csv[2].indexOf('eggs|goldhen eggs|') === 0, csv.join(' / '));
  T('the store line carries no pipe, so the pipe-splitting capture readers skip it', csv[0].indexOf('|') < 0, csv[0]);

  const mixed = {};
  mixed[KEY] = JSON.stringify({ 'goldhen eggs': { v: 'MATCHES', rows: [r.rows[0], { name: 'old row', prices: '$1.00', unit: '', size: '1 ct', href: '/x' }] } });
  const m = load(makePage(HEAD, []), mixed).aldiSearchToCsv({}).split('\n');
  T('MUST FIRE  a row with no store read gets its own UNRECORDED line, never folded into its neighbour',
    m[0] === '#tc-store store="ALDI - OLA 42 - Omaha" mode="In-Store" rows=1' && m[1] === '#tc-store store="UNRECORDED" mode="UNRECORDED" rows=1', m.slice(0, 2).join(' / '));

  const hostile = {};
  hostile[KEY] = JSON.stringify({ t: { v: 'MATCHES', rows: [Object.assign({}, r.rows[0], { st: 'ALDI - "OLA|42"\n- Omaha' })] } });
  const h = load(makePage(HEAD, []), hostile).aldiSearchToCsv({}).split('\n');
  T('a store string carrying a quote, pipe or newline cannot break its line', h[0] === '#tc-store store="ALDI - OLA 42 - Omaha" mode="In-Store" rows=1', h[0]);

  process.exit(bad === 0 ? 0 : 1);
})().catch(e => { console.log('  X     the Aldi capture test threw: ' + (e && e.stack)); process.exit(1); });
'@
$ald = Join-Path $here 'pull-aldi-instore.js'
$tmpA = Join-Path ([IO.Path]::GetTempPath()) ('aldistore-' + [guid]::NewGuid().ToString('N') + '.js')
[IO.File]::WriteAllText($tmpA, $jsA, (New-Object System.Text.UTF8Encoding($false)))
try {
  & $node $tmpA $ald
  if ($LASTEXITCODE -ne 0) { $bad++ }
} finally { Remove-Item $tmpA -Force -ErrorAction SilentlyContinue }

# --- 6. the WALMART capture must carry the store it was READ at -------------------------------------
# 2026-09-12, and this is the Aldi fix of section 5 arriving at the store that needed it most. Walmart
# prices ARE per-store and this agent asserted no store at all, so a session drifted to storeId 3153
# ("Omaha S 167th St Neighborhood Market") and the agent captured clean, plausible, wrong-basis prices
# at it twice - 414 rows on 2026-08-27 and 380 on 2026-09-12 - both caught only by a human reading the
# page header, and both quarantined by hand. build-walmart-deals.ps1 stamped "Omaha L St Supercenter
# 68137" on every row from a LITERAL and read no store from the capture, so it was structurally unable
# to notice. The agent now reads the store from __NEXT_DATA__ at assert time and on every response,
# and the mid-sweep flip is refused per term rather than left to the builder to find afterwards.
$jsWS = @'
const fs = require('fs');
const lib = fs.readFileSync(process.argv[2], 'utf8');
const src = fs.readFileSync(process.argv[3], 'utf8');
const wm = lib.match(/function wallWhy\(html, phrases\) \{[\s\S]*?\n\}/);
if (!wm) { console.log('  X     wallWhy is not defined in pull-agent-lib.js'); process.exit(1); }
eval(wm[0]);

let bad = 0;
function T(n, ok, got) { if (ok) console.log('  ok    ' + n); else { console.log('  X     ' + n + '   got: ' + got); bad++; } }

const LST  = { storeId: 5361, postalCode: '68137', displayName: 'Omaha L St Supercenter' };
const NBHD = { storeId: 3153, postalCode: '68135', displayName: 'Omaha S 167th St Neighborhood Market' };
const payload = (store, items) => ({ props: { pageProps: { initialData: {
  searchResult: { itemStacks: [{ items: items || [] }] },
  pageMetadata: store ? { location: store } : {},
} } } });
const html = o => '<html><body><script id="__NEXT_DATA__" type="application/json">' +
  JSON.stringify(o) + '</scr' + 'ipt></body></html>';
const item = (id, price) => ({ name: 'Great Value Thing ' + id, usItemId: String(id), sellerName: 'Walmart.com',
  fulfillmentType: 'STORE', priceInfo: { priceDetails: { priceLines: [
    { lineType: 'CURRENT_PRICE', values: [{ key: 'PRICE', value: String(price) }] } ] } } });

// The agent loads UNTOUCHED; only wallWhy, fetch, the page and its storage come from outside, so what
// is under test is the shipped file (sections 2, 4 and 5 follow the same rule, for the same reason).
function loadAgent(pageStore) {
  const ctx = { page: '', kv: {} };
  const doc = {
    body: { innerText: '' },
    getElementById: id => (id === '__NEXT_DATA__' && pageStore !== undefined)
      ? { textContent: JSON.stringify(payload(pageStore, [])) } : null,
  };
  const loc = { hostname: 'www.walmart.com' };
  const storage = { getItem: k => (k in ctx.kv ? ctx.kv[k] : null), setItem: (k, v) => { ctx.kv[k] = String(v); } };
  const stubFetch = async () => ({ status: 200, text: async () => ctx.page });
  const api = new Function('wallWhy', 'fetch', 'document', 'location', 'localStorage',
    src + '\nreturn { walmartIdentity, walmartProbe, walmartSweepToCsv, walmartStoreFromData, WALMART_SANCTIONED_STORE };')(
    wallWhy, stubFetch, doc, loc, storage);
  api.ctx = ctx;
  return api;
}

(async () => {
  // 1. THE READ ITSELF. The path the 2026-08-28 ruling names, and a payload shape that has moved
  //    three times already - so the read walks for the store rather than pinning one path.
  const a = loadAgent(LST);
  const who = a.walmartIdentity();
  T('walmartIdentity READS the store off __NEXT_DATA__, it no longer says there is nothing to assert',
    who.storeId === '5361' && who.postalCode === '68137' && /L St Supercenter/.test(who.store), JSON.stringify(who));
  T('...and the page location outscores an item node that also carries a storeId',
    a.walmartStoreFromData({ items: [{ storeId: 999, name: 'a product' }], pageMetadata: { location: LST } }).id === '5361',
    JSON.stringify(a.walmartStoreFromData({ items: [{ storeId: 999, name: 'a product' }], pageMetadata: { location: LST } })));

  // 2. MUST FIRE - the founding bug, twice over. A 3153 session must not capture a single row.
  let threw = '';
  try { loadAgent(NBHD).walmartIdentity(); } catch (e) { threw = e.message; }
  T('MUST FIRE  a session on storeId 3153 REFUSES to pull at all',
    /3153/.test(threw) && /5361/.test(threw), threw || 'it did not throw - a 3153 sweep would capture 380 plausible rows again');
  T('...and the refusal says it is the WRONG BASIS, not a wall or a missing selector',
    /BASIS/i.test(threw) && /switch the store/i.test(threw), threw);

  // 3. MUST FIRE - a store we cannot read is not a store we may assume. Blind is never a pass.
  let threwBlind = '';
  try { loadAgent(null).walmartIdentity(); } catch (e) { threwBlind = e.message; }
  T('MUST FIRE  a page whose __NEXT_DATA__ carries no store refuses the sweep',
    /no storeId/i.test(threwBlind), threwBlind || 'it did not throw');

  // 4. MUST FIRE - THE MID-SWEEP FLIP, which is why this is asserted per response and not once per
  //    run. pull-aldi-instore.js asserts per TERM for exactly this; a once-per-run assert cannot
  //    tell a clean sweep from a session that was flipped after it started.
  const f = loadAgent(LST);
  f.walmartIdentity();
  f.ctx.page = html(payload(NBHD, [item(1, '8.97')]));
  const rFlip = await f.walmartProbe('applesauce');
  T('MUST FIRE  a response priced at another store settles UNUSABLE with NO rows',
    rFlip.state === 'UNUSABLE' && rFlip.rows.length === 0, rFlip.state + ' / ' + rFlip.rows.length + ' row(s)');
  T('...and the verdict names both stores, so the ledger says what it refused',
    /3153/.test(rFlip.why || '') && /5361/.test(rFlip.why || ''), rFlip.why);

  // 5. CLEAN TWIN - the ordinary case is untouched: same store, rows kept, store on every row.
  const g = loadAgent(LST);
  g.walmartIdentity();
  g.ctx.page = html(payload(LST, [item(1, '8.97'), item(2, '2.50')]));
  const rOk = await g.walmartProbe('applesauce');
  T('CLEAN TWIN  a response at the asserted store still yields its rows',
    rOk.state === 'MATCHES' && rOk.rows.length === 2, rOk.state + ' / ' + rOk.rows.length + ' / ' + (rOk.why || ''));
  T('...and every row carries the store it was read at, read from its OWN response',
    rOk.rows.every(x => x.si === '5361' && x.sz === '68137' && x.st === 'Omaha L St Supercenter' && x.sr === 'response'),
    JSON.stringify(rOk.rows.map(x => [x.si, x.sz, x.sr])));

  // 5b. THE LIVE SHAPE, FROZEN FROM A MEASURED RESPONSE (2026-09-12, /search?q=anaheim peppers through
  //     Brad's own Chrome: HTTP 200, 876,030 bytes, 61 item nodes). Two things about it that no
  //     hand-written fixture would have guessed, and both decide the read: the store block carries NO
  //     display name, and 131 nodes in the payload carry a storeId - 130 of them the value 0, on item
  //     nodes. So the scoring is what makes this work, and the row's store NAME has to be borrowed
  //     from the asserted store. If either half regresses, this capture line goes out saying store=""
  //     or naming storeId 0, and the builder refuses every Walmart capture from then on.
  const liveStore = { storeId: 5361, postalCode: '68137' };            // no displayName - measured
  const liveItems = [];
  for (let i = 0; i < 130; i++) liveItems.push(Object.assign(item(1000 + i, '1.00'), { storeId: 0 }));
  const lv = loadAgent(LST);
  lv.walmartIdentity();
  lv.ctx.page = html(payload(liveStore, liveItems));
  const rLive = await lv.walmartProbe('anaheim peppers');
  T('THE LIVE SHAPE  a nameless store block beside 130 item nodes at storeId 0 still reads 5361/68137',
    rLive.state === 'MATCHES' && rLive.rows.length === 130 && rLive.rows.every(x => x.si === '5361' && x.sz === '68137'),
    rLive.state + ' / ' + rLive.rows.length + ' / ' + JSON.stringify((rLive.rows[0] || {}).si) + ' / ' + (rLive.why || ''));
  T('...and the row NAME is borrowed from the asserted store, never left empty and never storeId 0',
    (rLive.rows[0] || {}).st === 'Omaha L St Supercenter' && (rLive.rows[0] || {}).sr === 'response',
    JSON.stringify([(rLive.rows[0] || {}).st, (rLive.rows[0] || {}).sr]));

  // 5c. MUST FIRE - THE CASE A MUTATION PROBE ASKED FOR (2026-09-12). Dropping the page-location key
  //     bonus from the scoring SURVIVED the case above: against the measured payload the nameless
  //     location block still wins on its postal code (2) over 130 bare item nodes (1), so that fixture
  //     could not see whether the bonus worked. It is load-bearing against the shape RIGHT BESIDE the
  //     measured one - a node carrying a storeId, a postal code AND a name scores 3 and beats a
  //     nameless location block on merit alone. A marketplace seller's address block is exactly that.
  //     Without the bonus this capture would name somebody else's storeId, which is the wrong basis
  //     arriving by a different door.
  const rival = { storeId: 7777, postalCode: '90210', name: 'Some Seller Warehouse' };
  const rv = loadAgent(LST);
  rv.walmartIdentity();
  rv.ctx.page = html(payload(liveStore, [Object.assign(item(9, '5.00'), { seller: rival })]));
  const rRival = await rv.walmartProbe('anaheim peppers');
  T('MUST FIRE  a nameless page location still outranks a fully-named rival store node in the payload',
    rRival.state === 'MATCHES' && (rRival.rows[0] || {}).si === '5361',
    rRival.state + ' / ' + JSON.stringify((rRival.rows[0] || {}).si) + ' / ' + (rRival.why || ''));

  // 6. THE FALLBACK IS MARKED, NOT SILENT. A response with no store block is attributed to the store
  //    read at assert time - a known blind spot for those rows, which is why they say read="page"
  //    and get their own #tc-store line rather than being folded in with the proven ones.
  const h = loadAgent(LST);
  h.walmartIdentity();
  h.ctx.page = html(payload(null, [item(3, '1.25')]));
  const rFall = await h.walmartProbe('apples');
  T('a response with no store block falls back to the asserted store and SAYS so',
    rFall.state === 'MATCHES' && rFall.rows.length === 1 && rFall.rows[0].si === '5361' && rFall.rows[0].sr === 'page',
    rFall.state + ' / ' + JSON.stringify((rFall.rows[0] || {})));

  // 7. MUST FIRE - no assert and no store in the response is how both quarantines happened.
  const n = loadAgent(LST);
  n.ctx.page = html(payload(null, [item(4, '3.00')]));
  const rNone = await n.walmartProbe('apples');
  T('MUST FIRE  a probe run without walmartIdentity() keeps nothing when the response has no store',
    rNone.state === 'UNUSABLE' && rNone.rows.length === 0, rNone.state + ' / ' + (rNone.why || ''));

  // 8. MUST FIRE - two stores at equal confidence is not a store. Never resolved by a guess.
  const amb = loadAgent(LST).walmartStoreFromData({ a: { store: { storeId: 5361 } }, b: { store: { storeId: 3153 } } });
  T('MUST FIRE  two rival storeIds at equal confidence read as AMBIGUOUS, never as the first one',
    amb && amb.id === 'AMBIGUOUS', JSON.stringify(amb));

  // 9. THE CAPTURE LINE, which is what build-walmart-deals now rules on.
  //     The rows come from the REAL probe and are then persisted the way runPacedSweep persists them
  //     ({ term: { v, why, rows } }), so the emitter is fed the shipped extractor's own output rather
  //     than a hand-written row - the shape trap section 4's header describes, one level up.
  const e = loadAgent(LST);
  e.walmartIdentity();
  e.ctx.page = html(payload(LST, [item(1, '8.97'), item(2, '2.50')]));
  const rEmit = await e.walmartProbe('applesauce');
  T('the emitter is fed real probe output, not a hand-written row', rEmit.state === 'MATCHES' && rEmit.rows.length === 2, rEmit.state);
  e.ctx.kv['TC_WALMART_SWEEP'] = JSON.stringify({ applesauce: { v: 'MATCHES', why: null, rows: rEmit.rows },
                                                  kale: { v: 'EMPTY', why: 'no results', rows: [] } });
  const csv = e.walmartSweepToCsv().split('\n');
  T('CLEAN TWIN  the capture OPENS with the store line, counted',
    csv[0] === '#tc-store store="Omaha L St Supercenter" id="5361" zip="68137" read="response" rows=2', csv[0]);
  T('...then the column header, so the driver prepends nothing', csv[1] === 'q|n|lp|up|id|was|rb|sel|ff', csv[1]);
  T('...then exactly the rows, the search term first', csv.length === 4 && csv[2].indexOf('applesauce|') === 0, csv.join(' / '));
  T('the store line carries no pipe, so the pipe-splitting capture readers skip it as a short line',
    csv[0].indexOf('|') < 0, csv[0]);
  T('...and the 9-column positional contract build-walmart-deals reads is unchanged',
    csv[2].split('|').length === 9, csv[2]);

  // 10. MUST FIRE - a row persisted by an older agent has no store and must never be folded into one.
  const old = loadAgent(LST);
  old.ctx.kv['TC_WALMART_SWEEP'] = JSON.stringify({ t: { v: 'MATCHES', rows: [
    { n: 'proven row', lp: '$1.00', up: '', id: '1', was: '', rb: 0, sel: '', ff: '', st: 'Omaha L St Supercenter', si: '5361', sz: '68137', sr: 'response' },
    { n: 'row from an older agent', lp: '$2.00', up: '', id: '2', was: '', rb: 0, sel: '', ff: '' },
  ] } });
  const om = old.walmartSweepToCsv().split('\n');
  T('MUST FIRE  a row with no store read gets its own UNRECORDED line, never folded into its neighbour',
    om[0] === '#tc-store store="Omaha L St Supercenter" id="5361" zip="68137" read="response" rows=1' &&
    om[1] === '#tc-store store="UNRECORDED" id="UNRECORDED" zip="" read="UNRECORDED" rows=1', om.slice(0, 2).join(' / '));

  // 11. a store string carrying a quote, pipe or newline cannot break its own line.
  const hos = loadAgent(LST);
  hos.ctx.kv['TC_WALMART_SWEEP'] = JSON.stringify({ t: { v: 'MATCHES', rows: [
    { n: 'x', lp: '$1.00', up: '', id: '1', was: '', rb: 0, sel: '', ff: '', st: 'Omaha "L|St"\nSupercenter', si: '5361', sz: '68137', sr: 'response' } ] } });
  const hl = hos.walmartSweepToCsv().split('\n');
  T('a store string carrying a quote, pipe or newline cannot break its line',
    hl[0] === '#tc-store store="Omaha L St Supercenter" id="5361" zip="68137" read="response" rows=1', hl[0]);

  // 12. The sanctioned id is a MIRROR of stores.json -> Walmart -> store_identity. The agreement of
  //     the two copies is asserted in build-walmart-deals.ps1's self-test, which can read both files;
  //     this case only pins that the constant is still here to be compared.
  T('the agent carries the sanctioned store as a named constant, for the builder to check against',
    loadAgent(LST).WALMART_SANCTIONED_STORE.id === '5361', JSON.stringify(loadAgent(LST).WALMART_SANCTIONED_STORE));

  process.exit(bad === 0 ? 0 : 1);
})().catch(e => { console.log('  X     the Walmart store test threw: ' + (e && e.stack)); process.exit(1); });
'@
$tmpWS = Join-Path ([IO.Path]::GetTempPath()) ('wmstore-' + [guid]::NewGuid().ToString('N') + '.js')
[IO.File]::WriteAllText($tmpWS, $jsWS, (New-Object System.Text.UTF8Encoding($false)))
try {
  & $node $tmpWS $lib $wal
  if ($LASTEXITCODE -ne 0) { $bad++ }
} finally { Remove-Item $tmpWS -Force -ErrorAction SilentlyContinue }

if ($bad -eq 0) { Write-Output 'test-pull-agent-lib SELF-TEST PASS'; exit 0 }
Write-Output ("test-pull-agent-lib SELF-TEST FAIL: {0} case(s)" -f $bad); exit 1
