// live-price-fill.js - run a recipe card's OWN scripts in jsdom against a given feed and report what every
// live price placeholder ended up saying.
//
// WHY (2026-09-21, Brad: "The recipe pages should be fetching the pricing from our database ... If a pricing
// updates in the DB its automatically updated on all recipe pages."). A price in a recipe post is a
// <span data-tc-live-price data-tc-slug data-tc-field data-tc-basis> whose TEXT is the build-time fallback and
// which the card's own feed script fills at view time. This harness executes THAT script - the bytes the
// page ships, never a reimplementation - so a monitor built on it cannot pass by testing itself.
//
// Usage:  node live-price-fill.js <job.json>
//   job.json = { "jsdom": "<dir holding node_modules/jsdom>",
//                "feedPath": "<smp-feed.json on disk>" | null,
//                "feedMode": "ok" | "fail" | "http500",      (fail = network reject, http500 = r.ok false)
//                "cards": [ { "slug": "...", "htmlPath": "<file>", "kind": "body" | "page" } ] }
//   kind=body  a built card body (db\built\<slug>.body.html), wrapped in a bare article
//   kind=page  a whole served page; ONLY its .gh-content (the post) is executed, never the theme, the portal
//              or the site-wide injection, which would reach the network and prove nothing about the post
// Output: one JSON object per card on stdout, then the line LIVE-PRICE-FILL-COMPLETE cards=<n>.
'use strict';
const fs = require('fs');
const path = require('path');

const job = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, ''));
const { JSDOM, VirtualConsole } = require(path.join(job.jsdom, 'node_modules', 'jsdom'));
const FEED_URL = 'https://feed.thriftycrew.com/smp-feed.json';
const feedText = job.feedPath ? fs.readFileSync(job.feedPath, 'utf8').replace(/^\uFEFF/, '') : null;

function postHtml(card) {
  const raw = fs.readFileSync(card.htmlPath, 'utf8').replace(/^\uFEFF/, '');
  if (card.kind !== 'page') return raw;
  const d = new JSDOM(raw);                      // parse only, scripts NOT run
  const c = d.window.document.querySelector('.gh-content');
  return c ? c.innerHTML : null;
}

function shim(window, feedCalls) {
  window.fetch = function (url) {
    const u = String(url);
    feedCalls.push(u);
    if (u.split('?')[0] !== FEED_URL) return Promise.reject(new Error('monitor: no network for ' + u));
    if (job.feedMode === 'fail' || feedText === null) return Promise.reject(new Error('feed unreachable (fixture)'));
    if (job.feedMode === 'http500') return Promise.resolve({ ok: false, status: 500, json: () => Promise.resolve(null) });
    return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(JSON.parse(feedText)) });
  };
  window.matchMedia = window.matchMedia || function () { return { matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} }; };
  window.IntersectionObserver = window.IntersectionObserver || function () { return { observe() {}, unobserve() {}, disconnect() {} }; };
  window.ResizeObserver = window.ResizeObserver || function () { return { observe() {}, unobserve() {}, disconnect() {} }; };
  window.scrollTo = function () {};
  window.HTMLElement.prototype.scrollIntoView = function () {};
}

function readSpans(document) {
  return Array.from(document.querySelectorAll('[data-tc-live-price]')).map(function (s) {
    return {
      slug: s.getAttribute('data-tc-slug'),
      field: s.getAttribute('data-tc-field'),
      basis: s.getAttribute('data-tc-basis'),
      fallback: s.getAttribute('data-tc-fallback'),
      filled: s.getAttribute('data-tc-filled'),
      text: s.textContent,
    };
  });
}

async function runCard(card) {
  const out = { key: card.key || card.slug, slug: card.slug, ok: true, feedRequested: false, spans: [], scriptErrors: [] };
  const html = postHtml(card);
  if (html === null) { out.ok = false; out.error = 'no .gh-content in page'; return out; }
  if (card.dumpPost) fs.writeFileSync(card.dumpPost, html, 'utf8');   // the exact post bytes run below, for the caller's static checks
  const feedCalls = [];
  const vc = new VirtualConsole();
  vc.on('jsdomError', function (e) { out.scriptErrors.push(String(e && e.message || e).slice(0, 200)); });
  const dom = new JSDOM('<!doctype html><html><head></head><body class="post-template"><main><article class="gh-content">' + html + '</article></main></body></html>', {
    runScripts: 'dangerously', pretendToBeVisual: true, virtualConsole: vc,
    url: 'https://www.thriftycrew.com/' + card.slug + '/',
    beforeParse: function (w) { shim(w, feedCalls); },
  });
  const w = dom.window;
  // Wait for DOMContentLoaded work and the feed promise chain. A fill is synchronous once the feed resolves,
  // so the loop ends as soon as every placeholder says it was filled, or after the budget when it never is.
  const deadline = Date.now() + (job.waitMs || 4000);
  await new Promise((r) => setTimeout(r, 50));
  while (Date.now() < deadline) {
    const spans = readSpans(w.document);
    if (spans.length && spans.every((s) => s.filled)) break;
    if (job.feedMode && job.feedMode !== 'ok' && Date.now() > deadline - (job.waitMs || 4000) + 600) break;
    await new Promise((r) => setTimeout(r, 40));
  }
  out.feedRequested = feedCalls.some((u) => u.split('?')[0] === FEED_URL);
  out.spans = readSpans(w.document);
  // THE WIDGET THE PROSE MUST AGREE WITH: the receipt's Everyday tab, read the way a reader reads it (click
  // the tab, read the grand total and the servings box). The spans are read BEFORE this, so the click
  // cannot change what they said.
  try {
    const num = w.document.querySelector('.smp-sc-num');
    const btn = w.document.querySelector('.smp-ct-btn[data-t="everyday"]');
    if (btn) { btn.click(); await new Promise((r) => setTimeout(r, 30)); }
    const g = w.document.querySelector('.smp-ct-grand');
    const gt = g ? g.textContent : '';
    const m = gt.match(/\$\s?([\d,]+\.\d\d)/);
    out.everydayTab = { clicked: !!btn, grandText: gt.trim(), grand: m ? parseFloat(m[1].replace(/,/g, '')) : null, servings: num ? parseInt(num.value, 10) : null };
  } catch (e) { out.everydayTab = { error: String(e && e.message || e) }; }
  w.close();
  return out;
}

(async function () {
  let n = 0;
  for (const card of job.cards) {
    let r;
    try { r = await runCard(card); } catch (e) { r = { key: card.key || card.slug, slug: card.slug, ok: false, error: String(e && e.message || e) }; }
    process.stdout.write(JSON.stringify(r) + '\n');
    n++;
  }
  process.stdout.write('LIVE-PRICE-FILL-COMPLETE cards=' + n + '\n');
})();
