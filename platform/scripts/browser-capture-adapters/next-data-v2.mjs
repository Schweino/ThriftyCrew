import { mkdir, rename, writeFile } from "node:fs/promises";
import path from "node:path";

const TARGET_RESULTS = 25;
const CONFIG = {
  sams: {
    location: "Omaha Sam's Club",
    priceMode: "Pickup",
    url: (query) => `https://www.samsclub.com/s/${encodeURIComponent(query)}`,
    host: "https://www.samsclub.com",
  },
  walmart: {
    location: "Omaha L St Supercenter 12812 S 38TH St",
    priceMode: "Pickup",
    url: (query) => `https://www.walmart.com/search?q=${encodeURIComponent(query)}&facet=fulfillment_method%3APickup`,
    host: "https://www.walmart.com",
  },
};

function normalize(value) {
  return String(value ?? "").trim().toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function priceMinor(value) {
  const match = String(value ?? "").trim().match(/^\$([0-9][0-9,]*(?:\.[0-9]{1,2})?)$/);
  return match ? Math.round(Number(match[1].replace(/,/g, "")) * 100) : null;
}

async function atomicJson(file, value) {
  await mkdir(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  await rename(temporary, file);
}

async function readPage(tab) {
  return tab.playwright.evaluate(() => {
    const body = document.body.innerText;
    const data = JSON.parse(document.querySelector("#__NEXT_DATA__")?.textContent || "{}");
    const stacked = (data?.props?.pageProps?.initialData?.searchResult?.itemStacks || []).flatMap((stack) => [...(stack.items || []), ...(stack.itemsV2 || [])]);
    const structured = new Map();
    for (const item of stacked) {
      const id = String(item?.usItemId || "").trim();
      if (!id || structured.has(id)) continue;
      const canonical = new URL(item.canonicalUrl || `/ip/item/${id}`, location.origin);
      structured.set(id, {
        id,
        name: String(item.name || "").trim(),
        linePrice: String(item.priceInfo?.linePrice || item.priceInfo?.itemPrice || "").trim(),
        unitPrice: String(item.priceInfo?.unitPrice || "").trim(),
        taxonomy: String(item.category?.categoryPathId || item.departmentName || "").trim(),
        url: canonical.origin + canonical.pathname,
        imageUrl: String(item.imageInfo?.thumbnailUrl || "").trim(),
      });
    }
    const visible = new Map();
    for (const anchor of [...document.querySelectorAll("a")]) {
      const text = (anchor.innerText || anchor.getAttribute("aria-label") || "").replace(/\s+/g, " ").trim();
      if (!text || !anchor.href) continue;
      let decoded;
      try { decoded = decodeURIComponent(anchor.href); } catch { decoded = anchor.href; }
      const match = decoded.match(/\/(?:ip|p)\/[^/?#]*\/(\d{5,})(?:[?#/]|$)/i);
      if (!match) continue;
      const prior = visible.get(match[1]);
      if (!prior || text.length > prior.length) visible.set(match[1], text);
    }
    const rows = [];
    for (const item of structured.values()) {
      const visibleText = visible.get(item.id);
      if (!visibleText || !item.name || !item.linePrice) continue;
      const normalizedVisible = visibleText.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
      const normalizedName = item.name.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
      if (!visibleText.includes(item.linePrice) || !normalizedVisible.includes(normalizedName)) continue;
      rows.push({ ...item, visiblePrice: item.linePrice });
    }
    const query = document.querySelector('input[type="search"], input[role="searchbox"]')?.value || new URL(location.href).searchParams.get("q") || "";
    return {
      url: location.href,
      title: document.title,
      query,
      locale: document.documentElement.lang || "en-US",
      challenge: /verify you are human|captcha|access denied|unusual traffic|robot or human|403 error|request blocked|request could not be satisfied/i.test(body),
      noResults: /no (?:matching )?(?:results|products)|0 results|couldn.t find/i.test(body),
      hasMore: [...document.querySelectorAll("button,a")].some((element) => /^(?:next|next page|load more|show more)$/i.test((element.innerText || element.getAttribute("aria-label") || "").trim()) && element.offsetParent !== null),
      rows,
    };
  });
}

function buildRows(store, query, page, capturedAt) {
  const config = CONFIG[store];
  return page.rows.map((row, resultIndex) => {
    const purchasePriceMinor = priceMinor(row.linePrice);
    const priceSemantics = store === "sams"
      ? { offerType: "member", condition: "membership", unitPriceMinor: purchasePriceMinor, qualifyingQuantity: 1, totalPriceMinor: purchasePriceMinor, ambiguity: false }
      : { offerType: "everyday", condition: "none", unitPriceMinor: purchasePriceMinor, qualifyingQuantity: 1, totalPriceMinor: purchasePriceMinor, ambiguity: false };
    const truth = {
      capturedAt,
      pageUrl: page.url,
      location: config.location,
      priceMode: config.priceMode,
      pageIndex: 0,
      resultIndex,
      pageState: { pageType: "search_results", pageTitle: page.title, query: page.query, resultRegionPresent: true, challengeDetected: false, currency: "USD", locale: page.locale, locationText: config.location, fulfillmentText: config.priceMode },
      visible: { rawText: row.visiblePrice, priceMinor: purchasePriceMinor, productName: row.name, productKey: row.id, sizeText: "", priceSemantics },
      structured: { rawText: row.linePrice, priceMinor: purchasePriceMinor, productName: row.name, productKey: row.id, sizeText: "", priceSemantics },
      parser: { status: "exact", rule: "next-data-price-lines", notes: "Visible product-card price agrees with the projected __NEXT_DATA__ linePrice for the same retailer item ID." },
    };
    return { q: query, n: row.name, lp: row.linePrice, up: row.unitPrice, id: row.id, size: "", taxonomy_path: row.taxonomy, url: row.url, image_url: row.imageUrl, _capture: truth };
  });
}

async function captureTerm(tab, store, query) {
  const config = CONFIG[store];
  let lastError = "";
  for (let attempts = 1; attempts <= 2; attempts += 1) {
    const startedAt = new Date().toISOString();
    try {
      await tab.goto(config.url(query));
      let page = null;
      for (let poll = 0; poll < 20; poll += 1) {
        await tab.playwright.waitForTimeout(poll === 0 ? 800 : 300);
        page = await readPage(tab);
        if (page.challenge || page.rows.length || page.noResults) break;
      }
      const finishedAt = new Date().toISOString();
      if (page?.challenge) return { blocked: true, term: { query, outcome: "blocked", rowCount: 0, attempts, startedAt, finishedAt, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "blocked" }, reason: "Retailer challenge detected; sweep stopped without attempting to solve it." }, rows: [] };
      if (!page) throw new Error(`${store} page produced no readable state`);
      if (normalize(page.query) !== normalize(query)) throw new Error(`visible query mismatch: expected ${query}, saw ${page.query}`);
      if (page.rows.length === 0) {
        if (!page.noResults) throw new Error("zero visible/structured agreements without an explicit no-results state");
        return { blocked: false, term: { query, outcome: "empty", rowCount: 0, attempts, startedAt, finishedAt, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "no-results" } }, rows: [] };
      }
      if (page.rows.length < TARGET_RESULTS && page.hasMore) throw new Error("visible/structured agreement remained truncated below target depth while a continuation was present");
      if (page.rows.some((row) => priceMinor(row.linePrice) === null || !row.id || !row.name)) throw new Error("one or more agreed rows lacked an exact line price, retailer item ID, or name");
      const rows = buildRows(store, query, page, finishedAt);
      return { blocked: false, term: { query, outcome: "success", rowCount: rows.length, attempts, startedAt, finishedAt, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: rows.length, pageCount: 1, hasMoreResults: page.hasMore, termination: page.hasMore ? "target-depth" : "end-of-results" } }, rows };
    } catch (error) {
      lastError = String(error?.message || error);
      if (attempts < 2) await tab.playwright.waitForTimeout(500);
    }
  }
  const instant = new Date().toISOString();
  return { blocked: false, term: { query, outcome: "rejected", rowCount: 0, attempts: 2, startedAt: instant, finishedAt: instant, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "error" }, reason: lastError || `${store} capture failed twice` }, rows: [] };
}

async function captureCanary(tab, store, screenshotSha256) {
  const config = CONFIG[store];
  const state = await tab.playwright.evaluate(() => ({ url: location.href, body: document.body.innerText.slice(0, 2000), challenge: /verify you are human|captcha|access denied|unusual traffic|robot or human|403 error|request blocked|request could not be satisfied/i.test(document.body.innerText) }));
  const pass = store === "sams"
    ? /Pickup[\s\S]*Omaha Sam's Club/i.test(state.body)
    : /Omaha L St Supercenter/i.test(state.body) && /12812 S 38TH St/i.test(state.body) && /fulfillment_method%3APickup/i.test(state.url);
  if (state.challenge || !pass) throw new Error(`${store} Omaha/Pickup canary failed`);
  return { observedAt: new Date().toISOString(), market: "Omaha, NE", location: config.location, priceMode: config.priceMode, evidenceUrl: state.url, marketVerified: true, locationVerified: true, priceModeVerified: true, ...(screenshotSha256 ? { screenshotSha256 } : {}) };
}

export async function captureNextDataChunk({ tab, store, terms, file, screenshotSha256 }) {
  if (!CONFIG[store]) throw new Error("next-data adapter supports sams or walmart");
  if (!Array.isArray(terms) || terms.length < 1 || terms.length > 20) throw new Error(`${store} chunk requires 1-20 terms`);
  const canary = await captureCanary(tab, store, screenshotSha256);
  const results = [];
  for (const query of terms) {
    const captured = await captureTerm(tab, store, query);
    results.push(captured);
    await atomicJson(file, { version: 2, phase: "discovery", store, canary, terms: results.map((result) => result.term), rows: results.flatMap((result) => result.rows) });
    if (captured.blocked) break;
  }
  return { file, attempted: results.length, rows: results.reduce((total, result) => total + result.rows.length, 0), blocked: results.some((result) => result.blocked), rejected: results.filter((result) => result.term.outcome === "rejected").map((result) => ({ query: result.term.query, reason: result.term.reason })), empty: results.filter((result) => result.term.outcome === "empty").map((result) => result.term.query) };
}
