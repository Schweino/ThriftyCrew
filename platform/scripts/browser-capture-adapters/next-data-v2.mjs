import { browserLanePolicy, recordBrowserLaneResult, withBrowserStoreLane } from "./lane-policy.mjs";
import { checkpointAdapterChunk } from "./adapter-protocol.mjs";

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

function expandVerification(target, verification) {
  const rows = Array.isArray(target.satisfies) && target.satisfies.length ? target.satisfies : [target];
  return rows.map((row) => ({ ...verification, rowKey: row.rowKey, discoveryHash: row.discoveryHash }));
}

export function walmartPickupEligible(row) {
  return row?.availabilityStatus === "IN_STOCK"
    && Array.isArray(row.pickupStoreIds)
    && row.pickupStoreIds.includes("5361");
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
        availabilityStatus: String(item.availabilityStatusV2?.value || "").trim().toUpperCase(),
        pickupStoreIds: [...new Set((item.fulfillmentSummary || [])
          .filter((option) => String(option?.fulfillment || "").toUpperCase() === "PICKUP")
          .map((option) => String(option?.storeId || "").trim())
          .filter(Boolean))],
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
      challenge: /\/are-you-human|\/blocked|\/verify/i.test(location.pathname)
        || /verify you are human|captcha|access denied|unusual traffic|robot or human|not a robot|403 error|request blocked|request could not be satisfied/i.test(`${document.title}\n${body}`),
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
        if (store === "walmart") {
          const rawRowCount = page.rows.length;
          page.rows = page.rows.filter(walmartPickupEligible);
          page.pickupFilteredEmpty = rawRowCount > 0 && page.rows.length === 0;
        }
        if (page.challenge || page.rows.length || page.noResults || page.pickupFilteredEmpty) break;
      }
      const finishedAt = new Date().toISOString();
      if (page?.challenge) return { blocked: true, term: { query, outcome: "blocked", rowCount: 0, attempts, startedAt, finishedAt, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "blocked" }, reason: "Retailer challenge detected; sweep stopped without attempting to solve it." }, rows: [] };
      if (!page) throw new Error(`${store} page produced no readable state`);
      if (normalize(page.query) !== normalize(query)) throw new Error(`visible query mismatch: expected ${query}, saw ${page.query}`);
      if (page.rows.length === 0) {
        if (!page.noResults && !page.pickupFilteredEmpty) throw new Error("zero visible/structured agreements without an explicit no-results state");
        return { blocked: false, term: { query, outcome: "empty", rowCount: 0, attempts, startedAt, finishedAt, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "no-results" }, ...(page.pickupFilteredEmpty ? { reason: "all exact result agreements lacked in-stock pickup fulfillment at Walmart store 5361" } : {}) }, rows: [] };
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

export async function captureNextDataCanary(tab, store, screenshotSha256) {
  const config = CONFIG[store];
  let state;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    state = await tab.playwright.evaluate(() => ({
      url: location.href,
      body: document.body.innerText.slice(0, 2000),
      challenge: /\/are-you-human|\/blocked|\/verify/i.test(location.pathname)
        || /verify you are human|captcha|access denied|unusual traffic|robot or human|not a robot|403 error|request blocked|request could not be satisfied/i.test(`${document.title}\n${document.body.innerText}`),
    }));
    if (state.challenge) throw new Error(`${store} retailer block page detected; stop the lane without retrying or attempting a bypass`);
    const pass = store === "sams"
      ? /Pickup[\s\S]*Omaha Sam's Club/i.test(state.body)
      : /Omaha L St Supercenter/i.test(state.body) && /12812 S 38TH St/i.test(state.body) && /fulfillment_method%3APickup/i.test(state.url);
    if (pass) return { observedAt: new Date().toISOString(), market: "Omaha, NE", location: config.location, priceMode: config.priceMode, evidenceUrl: state.url, marketVerified: true, locationVerified: true, priceModeVerified: true, ...(screenshotSha256 ? { screenshotSha256 } : {}) };
    if (attempt < 4) await tab.playwright.waitForTimeout(750);
  }
  throw new Error(`${store} Omaha/Pickup canary failed after waiting for the page to settle`);
}

async function captureNextDataChunkInternal({ tab, store, terms, file, sessionDirectory, screenshotSha256, interTermDelayMs }) {
  if (!CONFIG[store]) throw new Error("next-data adapter supports sams or walmart");
  const policy = await browserLanePolicy(store);
  const maxTerms = policy.maxTerms;
  const effectiveDelayMs = Math.max(interTermDelayMs ?? 0, policy.dynamicDelayMs);
  if (!Array.isArray(terms) || terms.length < 1 || terms.length > maxTerms) throw new Error(`${store} chunk requires 1-${maxTerms} terms`);
  if (!Number.isInteger(effectiveDelayMs) || effectiveDelayMs < 0 || effectiveDelayMs > 30_000) throw new Error(`${store} inter-term delay must be 0-30000ms`);
  const canary = await captureNextDataCanary(tab, store, screenshotSha256);
  const results = [];
  const chunkStarted = Date.now();
  for (let index = 0; index < terms.length; index += 1) {
    const query = terms[index];
    const termStarted = Date.now();
    const captured = await captureTerm(tab, store, query);
    await recordBrowserLaneResult(store, captured.term.outcome, Date.now() - termStarted);
    const previousCount = results.length;
    results.push(captured);
    await checkpointAdapterChunk(file, { version: 2, phase: "discovery", store, canary, terms: results.map((result) => result.term), rows: results.flatMap((result) => result.rows) }, previousCount, sessionDirectory);
    if (captured.blocked) break;
    if (Date.now() - chunkStarted >= 45_000) break;
    if (index < terms.length - 1 && effectiveDelayMs > 0) await tab.playwright.waitForTimeout(effectiveDelayMs);
  }
  return { file, attempted: results.length, rows: results.reduce((total, result) => total + result.rows.length, 0), blocked: results.some((result) => result.blocked), rejected: results.filter((result) => result.term.outcome === "rejected").map((result) => ({ query: result.term.query, reason: result.term.reason })), empty: results.filter((result) => result.term.outcome === "empty").map((result) => result.term.query) };
}

async function captureNextDataVerificationChunkInternal({ tab, store, targets, file, sessionDirectory, screenshotSha256, interTermDelayMs }) {
  if (!CONFIG[store]) throw new Error("next-data verification adapter supports sams or walmart");
  const policy = await browserLanePolicy(store);
  const maxTargets = policy.maxTerms;
  const effectiveDelayMs = Math.max(interTermDelayMs ?? 0, policy.dynamicDelayMs);
  if (!Array.isArray(targets) || targets.length < 1 || targets.length > maxTargets) throw new Error(`${store} verification chunk requires 1-${maxTargets} targets`);
  if (!Number.isInteger(effectiveDelayMs) || effectiveDelayMs < 0 || effectiveDelayMs > 30_000) throw new Error(`${store} verification inter-target delay must be 0-30000ms`);
  const canary = await captureNextDataCanary(tab, store, screenshotSha256);
  const verifications = [];
  const chunkStarted = Date.now();
  for (let index = 0; index < targets.length; index += 1) {
    const target = targets[index];
    const previousCount = verifications.length;
    let captured = await captureTerm(tab, store, target.query);
    let row = captured.rows.find((candidate) => candidate.id === target.productKey);
    if (!captured.blocked && captured.term.outcome !== "blocked" && !row && normalize(target.name) !== normalize(target.query)) {
      if (effectiveDelayMs > 0) await tab.playwright.waitForTimeout(effectiveDelayMs);
      const exactNameCapture = await captureTerm(tab, store, target.name);
      if (exactNameCapture.blocked || exactNameCapture.term.outcome === "blocked") captured = exactNameCapture;
      else {
        const exactNameRow = exactNameCapture.rows.find((candidate) => candidate.id === target.productKey);
        if (exactNameRow) {
          captured = exactNameCapture;
          row = exactNameRow;
        }
      }
    }
    const observedAt = new Date().toISOString();
    if (captured.blocked || captured.term.outcome === "blocked") {
      verifications.push(...expandVerification(target, { observedAt, outcome: "blocked", reason: captured.term.reason || `${store} challenge detected during independent verification` }));
      await checkpointAdapterChunk(file, { version: 2, phase: "verification", store, canary, verifications }, previousCount, sessionDirectory);
      break;
    }
    if (!row) {
      verifications.push(...expandVerification(target, { observedAt, outcome: "missing", reason: captured.term.reason || "target product was absent from both the commodity and exact-name result envelopes" }));
    } else {
      const truth = { ...row._capture, capturedAt: observedAt };
      verifications.push(...expandVerification(target, {
        observedAt,
        outcome: "observed",
        productKey: row.id,
        name: row.n,
        sizeText: row.size,
        purchasePriceMinor: priceMinor(row.lp),
        truth,
      }));
    }
    await checkpointAdapterChunk(file, { version: 2, phase: "verification", store, canary, verifications }, previousCount, sessionDirectory);
    if (Date.now() - chunkStarted >= 45_000) break;
    if (index < targets.length - 1 && effectiveDelayMs > 0) await tab.playwright.waitForTimeout(effectiveDelayMs);
  }
  return {
    file,
    attempted: verifications.length,
    observed: verifications.filter((item) => item.outcome === "observed").length,
    missing: verifications.filter((item) => item.outcome === "missing").map((item) => item.rowKey),
    blocked: verifications.some((item) => item.outcome === "blocked"),
    budgetExhausted: Date.now() - chunkStarted >= 45_000,
  };
}

export async function captureNextDataChunk(options) {
  return withBrowserStoreLane(options.store, () => captureNextDataChunkInternal(options));
}

export async function captureNextDataVerificationChunk(options) {
  return withBrowserStoreLane(options.store, () => captureNextDataVerificationChunkInternal(options));
}
