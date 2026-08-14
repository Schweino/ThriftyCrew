import { browserLanePolicy, recordBrowserLaneResult, withBrowserStoreLane } from "./lane-policy.mjs";
import { checkpointAdapterChunk } from "./adapter-protocol.mjs";

const LOCATION = "Omaha 17070 Audrey Street";
const PRICE_MODE = "In-Store";
const TARGET_RESULTS = 25;

function normalize(value) {
  return String(value ?? "").trim().toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function expandVerification(target, verification) {
  const rows = Array.isArray(target.satisfies) && target.satisfies.length ? target.satisfies : [target];
  return rows.map((row) => ({ ...verification, rowKey: row.rowKey, discoveryHash: row.discoveryHash }));
}

export function validatedRegularPrice(currentPriceMinor, candidateRegularPriceMinor) {
  return Number.isInteger(candidateRegularPriceMinor) && candidateRegularPriceMinor > currentPriceMinor
    ? candidateRegularPriceMinor
    : undefined;
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
      const url = new URL(card.href);
      const idMatch = url.pathname.match(/\/products\/(\d+)(?:-|$)/);
      candidates.push({
        name,
        current,
        priceMinor: priceMatch ? Math.round(Number(priceMatch[1]) * 100) : null,
        size: nameIndex >= 0 ? (lines[nameIndex + 1] || "") : "",
        taxonomy: nameIndex >= 0 ? (lines[nameIndex + 2] || "") : "",
        href: url.origin + url.pathname,
        id: idMatch?.[1] || url.pathname.split("/").pop() || "",
        lines,
      });
    }
    const seen = new Set();
    return {
      url: location.href,
      title: document.title,
      query: document.querySelector('input[placeholder*="Search Fareway"]')?.value || "",
      locale: document.documentElement.lang || "en-US",
      challenge: /verify you are human|captcha|access denied|unusual traffic|403 error|request blocked|request could not be satisfied|robot or human/i.test(body),
      noResults: /no (?:matching )?(?:results|products)|0 results|couldn.t find/i.test(body),
      hasMore: [...document.querySelectorAll("button")].some((button) => /^(load|show) more$/i.test((button.innerText || "").trim()) && button.offsetParent !== null),
      rows: candidates.filter((row) => row.href && !seen.has(row.href) && (seen.add(row.href), true)),
    };
  });
}

export function buildFarewayRows(query, page, capturedAt) {
  const rows = [];
  const excludedResults = [];
  page.rows.forEach((row, resultIndex) => {
    try {
      if (!row.name) throw new Error("source-native product name is not exact");
      if (!row.id || !row.href) throw new Error("source-native product identity is not exact");
      if (!Number.isInteger(row.priceMinor)) throw new Error("source-native current price is not exact");
      if (!String(row.size ?? "").trim()) throw new Error("source-native package size is not exact");
    const originalLine = row.lines.find((line) => /^Original Price:\s*\$/i.test(line));
    const originalMatch = originalLine?.match(/\$([0-9]+(?:\.[0-9]{1,2})?)/);
    const regularPriceMinor = validatedRegularPrice(
      row.priceMinor,
      originalMatch ? Math.round(Number(originalMatch[1]) * 100) : undefined,
    );
    const priceSemantics = {
      offerType: regularPriceMinor ? "sale" : "everyday",
      condition: "none",
      unitPriceMinor: row.priceMinor,
      qualifyingQuantity: 1,
      totalPriceMinor: row.priceMinor,
      ...(regularPriceMinor ? { regularPriceMinor } : {}),
      ambiguity: false,
    };
    const availabilityText = row.lines.find((line) => /^(?:many in stock|in stock|low stock|only \d+ left)$/i.test(line)) || "";
    const inStock = /in stock|only \d+ left/i.test(availabilityText);
    const offer = { version: 1, retailerProductId: row.href, productName: row.name, sizeText: row.size, rawPriceText: row.current, purchasePriceMinor: row.priceMinor, availability: { status: inStock ? "in_stock" : "unknown", ...(availabilityText ? { rawText: availabilityText } : {}), fulfillmentMode: "in_store", eligible: inStock }, priceSemantics, observedAt: capturedAt, sourceUrl: row.href };
      rows.push({
      id: row.id,
      term: query,
      name: row.name,
      price: `$${(row.priceMinor / 100).toFixed(2)}`,
      per: "",
      orig: regularPriceMinor ? `$${(regularPriceMinor / 100).toFixed(2)}` : "",
      unit: "",
      size: row.size,
      url: row.href,
      taxonomy_path: row.taxonomy,
      availability_status: offer.availability.status,
      fulfillment_mode: offer.availability.fulfillmentMode,
      _capture: {
        capturedAt,
        pageUrl: page.url,
        location: LOCATION,
        priceMode: PRICE_MODE,
        pageIndex: 0,
        resultIndex,
        pageState: {
          pageType: "search_results",
          pageTitle: page.title,
          query: page.query,
          resultRegionPresent: true,
          challengeDetected: false,
          currency: "USD",
          locale: page.locale,
          locationText: LOCATION,
          fulfillmentText: PRICE_MODE,
        },
        visible: {
          rawText: row.current,
          priceMinor: row.priceMinor,
          productName: row.name,
          productKey: row.href,
          sizeText: row.size,
          priceSemantics,
        },
        offer,
        parser: {
          status: "exact",
          rule: "current-price-label",
          notes: "Fareway visible Current price label; exact Omaha store and In-Store mode verified by the chunk canary.",
        },
      },
      });
    } catch (error) {
      excludedResults.push({ productKey: String(row.id || row.href || `result-${resultIndex}`), name: String(row.name || "Unnamed retailer result"), reason: String(error?.message || error) });
    }
  });
  return { rows, excludedResults };
}

async function captureTerm(tab, query) {
  let lastError = "";
  for (let attempts = 1; attempts <= 2; attempts += 1) {
    const startedAt = new Date().toISOString();
    try {
      await tab.goto(`https://shop.fareway.com/store/fareway-meat-grocery/s?k=${encodeURIComponent(query)}`);
      let page = null;
      for (let poll = 0; poll < 16; poll += 1) {
        await tab.playwright.waitForTimeout(poll === 0 ? 650 : 250);
        page = await readPage(tab);
        if (page.challenge || page.rows.length || page.noResults) break;
      }
      let pageCount = 1;
      // A minimum result depth is sufficient when an exact eligible product is
      // found, but it cannot support a durable not-found conclusion. Continue
      // through the retailer's visible result envelope so QA can distinguish a
      // true absence from a broad query that merely reached TARGET_RESULTS.
      while (page && !page.challenge && page.rows.length > 0 && page.hasMore && pageCount < 10) {
        const more = tab.playwright.getByRole("button", { name: /^(Load|Show) more$/i }).filter({ visible: true });
        if (await more.count() < 1) throw new Error("continuation reported but visible Load more control is absent");
        const priorCount = page.rows.length;
        // Instacart-backed search pages can keep the main thread busy for more
        // than the browser client's default three-second action deadline.
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
      if (page?.challenge) {
        return {
          blocked: true,
          term: { query, outcome: "blocked", rowCount: 0, attempts, startedAt, finishedAt, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, pageCount, hasMoreResults: false, termination: "blocked" }, reason: "Retailer challenge detected; sweep stopped without attempting to solve it." },
          rows: [],
        };
      }
      if (!page) throw new Error("Fareway page produced no readable state");
      if (normalize(page.query) !== normalize(query)) throw new Error(`visible query mismatch: expected ${query}, saw ${page.query}`);
      if (page.rows.length === 0) {
        if (!page.noResults) throw new Error("zero cards without an explicit no-results state");
        return { blocked: false, term: { query, outcome: "empty", rowCount: 0, attempts, startedAt, finishedAt, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, availableResultCount: 0, pageCount, hasMoreResults: false, termination: "no-results" } }, rows: [] };
      }
      if (page.rows.length < TARGET_RESULTS && page.hasMore) throw new Error("pagination remained truncated below target depth");
      const built = buildFarewayRows(query, page, finishedAt);
      if (built.rows.length === 0) throw new Error(`all ${built.excludedResults.length} result rows failed exact offer projection`);
      const examinedResultCount = built.rows.length + built.excludedResults.length;
      return {
        blocked: false,
        term: { query, outcome: "success", rowCount: built.rows.length, attempts, startedAt, finishedAt, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: examinedResultCount, availableResultCount: examinedResultCount, pageCount, hasMoreResults: page.hasMore, termination: page.hasMore ? "target-depth" : "end-of-results" },
          ...(built.excludedResults.length ? { reason: `${built.excludedResults.length} retailer result(s) explicitly excluded from pricing`, excludedResults: built.excludedResults } : {}) },
        rows: built.rows,
      };
    } catch (error) {
      lastError = String(error?.message || error);
      if (attempts < 2) await tab.playwright.waitForTimeout(500);
    }
  }
  const instant = new Date().toISOString();
  return { blocked: false, term: { query, outcome: "rejected", rowCount: 0, attempts: 2, startedAt: instant, finishedAt: instant, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "error" }, reason: lastError || "Fareway capture failed twice" }, rows: [] };
}

async function captureCanary(tab, screenshotSha256) {
  const state = await tab.playwright.evaluate(() => ({
    url: location.href,
    challenge: /verify you are human|captcha|access denied|unusual traffic|403 error|request blocked|request could not be satisfied|robot or human/i.test(document.body.innerText),
    plainOmaha: [...document.querySelectorAll("button")].some((button) => /In-Store[\s\S]*Omaha/i.test(button.innerText || "") && !/Omaha (?:Meat Market|- North)/i.test(button.innerText || "")),
  }));
  const visibleHeaders = await tab.playwright.getByRole("button", { name: /In-Store.*Omaha/ }).filter({ visible: true }).count();
  if (state.challenge || !state.plainOmaha || visibleHeaders < 1) throw new Error("Fareway Omaha/In-Store canary failed");
  return { observedAt: new Date().toISOString(), market: "Omaha, NE", location: LOCATION, priceMode: PRICE_MODE, evidenceUrl: state.url, marketVerified: true, locationVerified: true, priceModeVerified: true, ...(screenshotSha256 ? { screenshotSha256 } : {}) };
}

async function readProductDetail(tab) {
  return tab.playwright.evaluate(() => {
    const body = document.body.innerText;
    const heading = document.querySelector("h1");
    const root = heading?.parentElement;
    const productId = location.pathname.match(/\/products\/(\d+)(?:-|$)/)?.[1] || "";
    const exactLink = root ? [...root.querySelectorAll('a[href*="/products/"]')].find((link) => {
      try { return new URL(link.href).pathname.match(/\/products\/(\d+)(?:-|$)/)?.[1] === productId; } catch { return false; }
    }) : null;
    const exactPriceNode = exactLink ? [...exactLink.querySelectorAll("*")].find((node) => /^Current price:\s*\$[0-9]+(?:\.[0-9]{1,2})?$/i.test((node.textContent || "").trim())) : null;
    const orderedNodes = [...document.querySelectorAll("h1, span.screen-reader-only")];
    const headingIndex = orderedNodes.indexOf(heading);
    const followingPriceNode = !exactPriceNode && headingIndex >= 0 ? orderedNodes.slice(headingIndex + 1).find((node) => (
      /^Current price:\s*\$[0-9]+(?:\.[0-9]{1,2})?(?:\s+.*)?$/i.test((node.textContent || "").trim())
    )) : null;
    const currentNode = exactPriceNode || followingPriceNode;
    const current = (currentNode?.textContent || "").trim();
    let priceScope = exactLink || currentNode?.parentElement || null;
    for (let depth = 0; depth < 6 && priceScope && !/Original Price:\s*\$/i.test(priceScope.innerText || ""); depth += 1) priceScope = priceScope.parentElement;
    const original = priceScope ? ([...priceScope.querySelectorAll("*")].map((node) => (node.textContent || "").trim()).find((text) => /^Original Price:\s*\$[0-9]+(?:\.[0-9]{1,2})?(?:\s+.*)?$/i.test(text)) || "") : "";
    const currentMatch = current.match(/\$([0-9]+(?:\.[0-9]{1,2})?)/);
    const originalMatch = original.match(/\$([0-9]+(?:\.[0-9]{1,2})?)/);
    const lines = (root?.innerText || "").split(/\n+/).map((line) => line.trim()).filter(Boolean);
    const itemIndex = lines.findIndex((line) => /^Item:\s*/i.test(line));
    const size = itemIndex >= 0 ? (lines.slice(itemIndex + 1).find((line) => !/^\s*[•$]|^(?:Current|Original) price:/i.test(line)) || "") : "";
    const canonicalUrl = `${location.origin}${location.pathname}`;
    return {
      url: canonicalUrl,
      title: document.title,
      locale: document.documentElement.lang || "en-US",
      name: (heading?.innerText || "").trim(),
      size,
      current,
      priceMinor: currentMatch ? Math.round(Number(currentMatch[1]) * 100) : null,
      regularPriceMinor: originalMatch ? Math.round(Number(originalMatch[1]) * 100) : null,
      challenge: /verify you are human|captcha|access denied|unusual traffic|403 error|request blocked|request could not be satisfied|robot or human/i.test(body),
      unavailable: /(?:item|product) (?:is )?(?:unavailable|not found)|page not found|404/i.test(body),
      plainOmaha: [...document.querySelectorAll("button")].some((button) => /In-Store[\s\S]*Omaha/i.test(button.innerText || "") && !/Omaha (?:Meat Market|- North)/i.test(button.innerText || "")),
    };
  });
}

async function captureProductDetail(tab, target) {
  let lastError = "";
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    try {
      await tab.goto(target.productKey);
      let page = null;
      for (let poll = 0; poll < 16; poll += 1) {
        await tab.playwright.waitForTimeout(poll === 0 ? 650 : 250);
        page = await readProductDetail(tab);
        if (page.challenge || page.unavailable || (page.name && Number.isInteger(page.priceMinor))) break;
      }
      if (!page) throw new Error("Fareway product page produced no readable state");
      if (page.challenge) return { outcome: "blocked", reason: "Retailer challenge detected on the product-detail verification page." };
      if (page.unavailable) return { outcome: "missing", reason: "Fareway reports the product is unavailable or missing." };
      if (!page.plainOmaha) throw new Error("Fareway product-detail page lost the Omaha/In-Store context");
      if (page.url !== target.productKey) return { outcome: "missing", reason: `product detail redirected from ${target.productKey} to ${page.url}` };
      if (!page.name || !page.size || !Number.isInteger(page.priceMinor) || !page.current) throw new Error("product detail lacked exact name, size, or Current price label");
      const observedAt = new Date().toISOString();
      const regularPriceMinor = validatedRegularPrice(page.priceMinor, page.regularPriceMinor);
      const priceSemantics = {
        offerType: regularPriceMinor ? "sale" : "everyday",
        condition: "none",
        unitPriceMinor: page.priceMinor,
        qualifyingQuantity: 1,
        totalPriceMinor: page.priceMinor,
        ...(regularPriceMinor ? { regularPriceMinor } : {}),
        ambiguity: false,
      };
      const offer = { version: 1, retailerProductId: page.url, productName: page.name, sizeText: page.size, rawPriceText: page.current, purchasePriceMinor: page.priceMinor, availability: { status: "unknown", fulfillmentMode: "in_store", eligible: false }, priceSemantics, observedAt, sourceUrl: page.url };
      return {
        outcome: "observed",
        observedAt,
        productKey: page.url,
        name: page.name,
        sizeText: page.size,
        purchasePriceMinor: page.priceMinor,
        truth: {
          capturedAt: observedAt,
          pageUrl: page.url,
          location: LOCATION,
          priceMode: PRICE_MODE,
          pageIndex: 0,
          resultIndex: 0,
          pageState: {
            pageType: "product_detail",
            pageTitle: page.title,
            resultRegionPresent: true,
            challengeDetected: false,
            currency: "USD",
            locale: page.locale,
            locationText: LOCATION,
            fulfillmentText: PRICE_MODE,
          },
          visible: {
            rawText: page.current,
            priceMinor: page.priceMinor,
            productName: page.name,
            productKey: page.url,
            sizeText: page.size,
            priceSemantics,
          },
          offer,
          parser: {
            status: "exact",
            rule: "current-price-label",
            notes: "Independent Fareway product-detail Current price label with exact Omaha/In-Store context.",
          },
        },
      };
    } catch (error) {
      lastError = String(error?.message || error);
      if (attempt < 2) await tab.playwright.waitForTimeout(500);
    }
  }
  return { outcome: "missing", reason: lastError || "Fareway product-detail verification failed twice" };
}

function verificationMatchesTarget(target, captured) {
  return captured.outcome === "observed"
    && captured.productKey === target.productKey
    && normalize(captured.name) === normalize(target.name)
    && normalize(captured.sizeText) === normalize(target.sizeText)
    && captured.purchasePriceMinor === target.purchasePriceMinor;
}

async function captureExactNameVerification(tab, target, detailReason) {
  const search = await captureTerm(tab, target.name);
  const observedAt = new Date().toISOString();
  if (search.blocked || search.term.outcome === "blocked") return { outcome: "blocked", observedAt, reason: search.term.reason || "Fareway challenge detected during exact-name verification" };
  const row = search.rows.find((candidate) => candidate.url === target.productKey);
  if (!row) return { outcome: "missing", observedAt, reason: `${detailReason}; exact-name search did not reproduce the target card` };
  return {
    outcome: "observed",
    observedAt,
    productKey: row.url,
    name: row.name,
    sizeText: row.size,
    purchasePriceMinor: Math.round(Number(String(row.price).replace(/[^0-9.]/g, "")) * 100),
    truth: { ...row._capture, capturedAt: observedAt },
  };
}

async function captureFarewayChunkInternal({ tab, terms, file, sessionDirectory, screenshotSha256 }) {
  const policy = await browserLanePolicy("fareway");
  if (!Array.isArray(terms) || terms.length < 1 || terms.length > policy.maxTerms) throw new Error(`Fareway chunk requires 1-${policy.maxTerms} terms`);
  const canary = await captureCanary(tab, screenshotSha256);
  const results = [];
  const chunkStarted = Date.now();
  for (let index = 0; index < terms.length; index += 1) {
    const query = terms[index];
    const termStarted = Date.now();
    const captured = await captureTerm(tab, query);
    await recordBrowserLaneResult("fareway", captured.term.outcome, Date.now() - termStarted);
    const previousCount = results.length;
    results.push(captured);
    const chunk = { version: 2, phase: "discovery", store: "fareway", canary, terms: results.map((result) => result.term), rows: results.flatMap((result) => result.rows) };
    await checkpointAdapterChunk(file, chunk, previousCount, sessionDirectory);
    if (captured.blocked) break;
    if (Date.now() - chunkStarted >= 45_000) break;
    if (index < terms.length - 1) await tab.playwright.waitForTimeout(policy.dynamicDelayMs);
  }
  return {
    file,
    attempted: results.length,
    rows: results.reduce((total, result) => total + result.rows.length, 0),
    blocked: results.some((result) => result.blocked),
    rejected: results.filter((result) => result.term.outcome === "rejected").map((result) => ({ query: result.term.query, reason: result.term.reason })),
    empty: results.filter((result) => result.term.outcome === "empty").map((result) => result.term.query),
  };
}

async function captureFarewayVerificationChunkInternal({ tab, targets, file, sessionDirectory, screenshotSha256 }) {
  const policy = await browserLanePolicy("fareway");
  if (!Array.isArray(targets) || targets.length < 1 || targets.length > policy.maxTerms) throw new Error(`Fareway verification chunk requires 1-${policy.maxTerms} targets`);
  const canary = await captureCanary(tab, screenshotSha256);
  const verifications = [];
  const chunkStarted = Date.now();
  for (let index = 0; index < targets.length; index += 1) {
    const target = targets[index];
    const previousCount = verifications.length;
    const detail = await captureProductDetail(tab, target);
    const captured = detail.outcome === "blocked" || verificationMatchesTarget(target, detail)
      ? detail
      : await captureExactNameVerification(tab, target, detail.outcome === "observed"
        ? "product-detail identity, size, or price disagreed with discovery"
        : (detail.reason || "product detail was not independently readable"));
    const observedAt = captured.observedAt || new Date().toISOString();
    if (captured.outcome === "blocked") {
      verifications.push(...expandVerification(target, { observedAt, outcome: "blocked", reason: captured.reason || "Fareway challenge detected during independent verification" }));
      await checkpointAdapterChunk(file, { version: 2, phase: "verification", store: "fareway", canary, verifications }, previousCount, sessionDirectory);
      break;
    }
    if (captured.outcome !== "observed") {
      verifications.push(...expandVerification(target, { observedAt, outcome: "missing", reason: captured.reason || "target product detail was not independently readable" }));
    } else {
      verifications.push(...expandVerification(target, {
        observedAt,
        outcome: "observed",
        productKey: captured.productKey,
        name: captured.name,
        sizeText: captured.sizeText,
        purchasePriceMinor: captured.purchasePriceMinor,
        truth: captured.truth,
      }));
    }
    await checkpointAdapterChunk(file, { version: 2, phase: "verification", store: "fareway", canary, verifications }, previousCount, sessionDirectory);
    if (Date.now() - chunkStarted >= 45_000) break;
    if (index < targets.length - 1) await tab.playwright.waitForTimeout(policy.dynamicDelayMs);
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

export async function captureFarewayChunk(options) {
  return withBrowserStoreLane("fareway", () => captureFarewayChunkInternal(options));
}

export async function captureFarewayVerificationChunk(options) {
  return withBrowserStoreLane("fareway", () => captureFarewayVerificationChunkInternal(options));
}
