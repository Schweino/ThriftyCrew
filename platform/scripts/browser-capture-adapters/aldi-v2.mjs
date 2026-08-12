import { browserLanePolicy, recordBrowserLaneResult, withBrowserStoreLane } from "./lane-policy.mjs";
import { checkpointAdapterChunk } from "./adapter-protocol.mjs";

const LOCATION = "ALDI - OLA 42 - Omaha";
const PRICE_MODE = "In-Store";
const TARGET_RESULTS = 25;
const MAX_TERMS_PER_CHUNK = 3;
const DEFAULT_INTER_TERM_DELAY_MS = 5_000;

function normalize(value) {
  return String(value ?? "").trim().toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function expandVerification(target, verification) {
  const rows = Array.isArray(target.satisfies) && target.satisfies.length ? target.satisfies : [target];
  return rows.map((row) => ({ ...verification, rowKey: row.rowKey, discoveryHash: row.discoveryHash }));
}

async function readPage(tab) {
  return tab.playwright.evaluate(() => {
    const body = document.body.innerText;
    const candidates = [];
    for (const image of [...document.querySelectorAll('[data-testid="item-card-image"]')]) {
      let node = image;
      let card = null;
      for (let depth = 0; depth < 10 && node; depth += 1, node = node.parentElement) {
        const text = (node.innerText || "").trim();
        const link = node.querySelector?.('a[href*="/products/"]');
        if (text.includes("Current price") && link) {
          card = { text, href: link.href };
          break;
        }
      }
      if (!card) continue;
      const lines = card.text.split(/\n+/).map((line) => line.trim()).filter(Boolean);
      const name = (image.getAttribute("alt") || "").trim();
      const current = lines.find((line) => /^Current price:\s*\$/i.test(line)) || "";
      const priceMatch = current.match(/\$([0-9]+(?:\.[0-9]{1,2})?)/);
      const nameIndex = lines.findIndex((line) => line === name);
      const trailing = nameIndex >= 0 ? lines.slice(nameIndex + 1) : [];
      const size = trailing[0] || "";
      const taxonomy = trailing.slice(1).find((line) => !/^(?:many in stock|in stock|low stock|only \d+ left|add)$/i.test(line)) || "";
      const url = new URL(card.href);
      const idMatch = url.pathname.match(/\/products\/(\d+)(?:-|$)/);
      candidates.push({ name, current, priceMinor: priceMatch ? Math.round(Number(priceMatch[1]) * 100) : null, size, taxonomy, href: url.origin + url.pathname, id: idMatch?.[1] || url.pathname.split("/").pop() || "", lines });
    }
    const seen = new Set();
    return {
      url: location.href,
      title: document.title,
      query: new URL(location.href).searchParams.get("k") || [...document.querySelectorAll('input[type="text"]')].map((input) => input.value).find(Boolean) || "",
      locale: document.documentElement.lang || "en-US",
      challenge: /verify you are human|captcha|access denied|unusual traffic|403 error|request blocked|request could not be satisfied/i.test(body),
      noResults: /no (?:matching )?(?:results|products)|0 results|couldn.t find/i.test(body),
      hasMore: [...document.querySelectorAll("button")].some((button) => /^(load|show) more$/i.test((button.innerText || "").trim()) && button.offsetParent !== null),
      rows: candidates.filter((row) => row.href && !seen.has(row.href) && (seen.add(row.href), true)),
    };
  });
}

function buildRows(query, page, capturedAt) {
  return page.rows.map((row, resultIndex) => {
    const originalLine = row.lines.find((line) => /^Original Price:\s*\$/i.test(line));
    const originalMatch = originalLine?.match(/\$([0-9]+(?:\.[0-9]{1,2})?)/);
    const regularPriceMinor = originalMatch ? Math.round(Number(originalMatch[1]) * 100) : undefined;
    const priceSemantics = { offerType: regularPriceMinor ? "sale" : "everyday", condition: "none", unitPriceMinor: row.priceMinor, qualifyingQuantity: 1, totalPriceMinor: row.priceMinor, ...(regularPriceMinor ? { regularPriceMinor } : {}), ambiguity: false };
    return {
      id: row.id,
      term: query,
      name: row.name,
      prices: `$${(row.priceMinor / 100).toFixed(2)}`,
      unit: "",
      size: row.size,
      href: row.href,
      taxonomy_path: row.taxonomy,
      _capture: {
        capturedAt,
        pageUrl: page.url,
        location: LOCATION,
        priceMode: PRICE_MODE,
        pageIndex: 0,
        resultIndex,
        pageState: { pageType: "search_results", pageTitle: page.title, query: page.query, resultRegionPresent: true, challengeDetected: false, currency: "USD", locale: page.locale, locationText: LOCATION, fulfillmentText: PRICE_MODE },
        visible: { rawText: row.current, priceMinor: row.priceMinor, productName: row.name, productKey: row.href, sizeText: row.size, priceSemantics },
        parser: { status: "exact", rule: "current-price-label", notes: "ALDI visible Current price label; OLA 42 Omaha and In-Store mode verified by the chunk canary." },
      },
    };
  });
}

async function captureTerm(tab, query) {
  let lastError = "";
  for (let attempts = 1; attempts <= 2; attempts += 1) {
    const startedAt = new Date().toISOString();
    try {
      await tab.goto(`https://www.aldi.us/store/aldi/s?k=${encodeURIComponent(query)}`);
      let page = null;
      for (let poll = 0; poll < 16; poll += 1) {
        await tab.playwright.waitForTimeout(poll === 0 ? 650 : 250);
        page = await readPage(tab);
        if (page.challenge || page.rows.length || page.noResults) break;
      }
      let pageCount = 1;
      while (page && !page.challenge && page.rows.length > 0 && page.rows.length < TARGET_RESULTS && page.hasMore && pageCount < 5) {
        const more = tab.playwright.getByRole("button", { name: /^(Load|Show) more$/i }).filter({ visible: true });
        if (await more.count() < 1) throw new Error("continuation reported but visible Load more control is absent");
        const priorCount = page.rows.length;
        await tab.playwright.waitForTimeout(750);
        await more.click({ force: true, timeoutMs: 10_000 });
        pageCount += 1;
        for (let poll = 0; poll < 16; poll += 1) {
          await tab.playwright.waitForTimeout(250);
          page = await readPage(tab);
          if (page.rows.length > priorCount || !page.hasMore || page.challenge) break;
        }
      }
      const finishedAt = new Date().toISOString();
      if (page?.challenge) return { blocked: true, term: { query, outcome: "blocked", rowCount: 0, attempts, startedAt, finishedAt, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, pageCount, hasMoreResults: false, termination: "blocked" }, reason: "Retailer challenge detected; sweep stopped without attempting to solve it." }, rows: [] };
      if (!page) throw new Error("ALDI page produced no readable state");
      if (normalize(page.query) !== normalize(query)) throw new Error(`visible query mismatch: expected ${query}, saw ${page.query}`);
      if (page.rows.length === 0) {
        if (!page.noResults) throw new Error("zero cards without an explicit no-results state");
        return { blocked: false, term: { query, outcome: "empty", rowCount: 0, attempts, startedAt, finishedAt, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, pageCount, hasMoreResults: false, termination: "no-results" } }, rows: [] };
      }
      if (page.rows.length < TARGET_RESULTS && page.hasMore) throw new Error("pagination remained truncated below target depth");
      if (page.rows.some((row) => !row.name || !row.id || !Number.isInteger(row.priceMinor))) throw new Error("one or more ALDI cards lacked exact identity/name/current price");
      const rows = buildRows(query, page, finishedAt);
      return { blocked: false, term: { query, outcome: "success", rowCount: rows.length, attempts, startedAt, finishedAt, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: rows.length, pageCount, hasMoreResults: page.hasMore, termination: page.hasMore ? "target-depth" : "end-of-results" } }, rows };
    } catch (error) {
      lastError = String(error?.message || error);
      if (attempts < 2) await tab.playwright.waitForTimeout(500);
    }
  }
  const instant = new Date().toISOString();
  return { blocked: false, term: { query, outcome: "rejected", rowCount: 0, attempts: 2, startedAt: instant, finishedAt: instant, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "error" }, reason: lastError || "ALDI capture failed twice" }, rows: [] };
}

async function captureCanary(tab, screenshotSha256) {
  const state = await tab.playwright.evaluate(() => ({ url: location.href, challenge: /verify you are human|captcha|access denied|unusual traffic|403 error|request blocked|request could not be satisfied/i.test(document.body.innerText), exact: document.body.innerText.includes("In-Store") && document.body.innerText.includes("ALDI - OLA 42 - Omaha") }));
  if (state.challenge) throw new Error("ALDI retailer block page detected; stop the lane without retrying or attempting a bypass");
  if (!state.exact) throw new Error("ALDI OLA 42 Omaha/In-Store canary failed");
  return { observedAt: new Date().toISOString(), market: "Omaha, NE", location: LOCATION, priceMode: PRICE_MODE, evidenceUrl: state.url, marketVerified: true, locationVerified: true, priceModeVerified: true, ...(screenshotSha256 ? { screenshotSha256 } : {}) };
}

async function captureAldiChunkInternal({ tab, terms, file, sessionDirectory, screenshotSha256, interTermDelayMs = DEFAULT_INTER_TERM_DELAY_MS }) {
  const policy = await browserLanePolicy("aldi");
  if (!Array.isArray(terms) || terms.length < 1 || terms.length > policy.maxTerms) throw new Error(`ALDI chunk requires 1-${policy.maxTerms} terms`);
  interTermDelayMs = Math.max(interTermDelayMs, policy.dynamicDelayMs);
  if (!Number.isInteger(interTermDelayMs) || interTermDelayMs < 0 || interTermDelayMs > 30_000) throw new Error("ALDI inter-term delay must be 0-30000ms");
  const canary = await captureCanary(tab, screenshotSha256);
  const results = [];
  const chunkStarted = Date.now();
  for (let index = 0; index < terms.length; index += 1) {
    const query = terms[index];
    const termStarted = Date.now();
    const captured = await captureTerm(tab, query);
    await recordBrowserLaneResult("aldi", captured.term.outcome, Date.now() - termStarted);
    const previousCount = results.length;
    results.push(captured);
    await checkpointAdapterChunk(file, { version: 2, phase: "discovery", store: "aldi", canary, terms: results.map((result) => result.term), rows: results.flatMap((result) => result.rows) }, previousCount, sessionDirectory);
    if (captured.blocked) break;
    if (Date.now() - chunkStarted >= 45_000) break;
    if (index < terms.length - 1 && interTermDelayMs > 0) await tab.playwright.waitForTimeout(interTermDelayMs);
  }
  return { file, attempted: results.length, rows: results.reduce((total, result) => total + result.rows.length, 0), blocked: results.some((result) => result.blocked), rejected: results.filter((result) => result.term.outcome === "rejected").map((result) => ({ query: result.term.query, reason: result.term.reason })), empty: results.filter((result) => result.term.outcome === "empty").map((result) => result.term.query) };
}

async function captureAldiVerificationChunkInternal({ tab, targets, file, sessionDirectory, screenshotSha256, interTermDelayMs = DEFAULT_INTER_TERM_DELAY_MS }) {
  const policy = await browserLanePolicy("aldi");
  if (!Array.isArray(targets) || targets.length < 1 || targets.length > policy.maxTerms) throw new Error(`ALDI verification chunk requires 1-${policy.maxTerms} targets`);
  interTermDelayMs = Math.max(interTermDelayMs, policy.dynamicDelayMs);
  if (!Number.isInteger(interTermDelayMs) || interTermDelayMs < 0 || interTermDelayMs > 30_000) throw new Error("ALDI verification inter-target delay must be 0-30000ms");
  const canary = await captureCanary(tab, screenshotSha256);
  const verifications = [];
  const chunkStarted = Date.now();
  for (let index = 0; index < targets.length; index += 1) {
    const target = targets[index];
    const previousCount = verifications.length;
    const captured = await captureTerm(tab, target.query);
    const observedAt = new Date().toISOString();
    if (captured.blocked || captured.term.outcome === "blocked") {
      verifications.push(...expandVerification(target, { observedAt, outcome: "blocked", reason: captured.term.reason || "ALDI challenge detected during independent verification" }));
      await checkpointAdapterChunk(file, { version: 2, phase: "verification", store: "aldi", canary, verifications }, previousCount, sessionDirectory);
      break;
    }
    const row = captured.rows.find((candidate) => candidate.href === target.productKey);
    if (!row) {
      verifications.push(...expandVerification(target, { observedAt, outcome: "missing", reason: captured.term.reason || "target product was not present in the independently reloaded result envelope" }));
    } else {
      const truth = { ...row._capture, capturedAt: observedAt };
      verifications.push(...expandVerification(target, {
        observedAt,
        outcome: "observed",
        productKey: row.href,
        name: row.name,
        sizeText: row.size,
        purchasePriceMinor: Math.round(Number(String(row.prices).replace(/[^0-9.]/g, "")) * 100),
        truth,
      }));
    }
    await checkpointAdapterChunk(file, { version: 2, phase: "verification", store: "aldi", canary, verifications }, previousCount, sessionDirectory);
    if (Date.now() - chunkStarted >= 45_000) break;
    if (index < targets.length - 1 && interTermDelayMs > 0) await tab.playwright.waitForTimeout(interTermDelayMs);
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

export async function captureAldiChunk(options) {
  return withBrowserStoreLane("aldi", () => captureAldiChunkInternal(options));
}

export async function captureAldiVerificationChunk(options) {
  return withBrowserStoreLane("aldi", () => captureAldiVerificationChunkInternal(options));
}
